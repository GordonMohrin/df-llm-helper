-- water (live L3): water for the bedridden. In L2 and L3 bedridden dwarves died of thirst: the hospital and
-- refuge wells stood over dry sumps, the only water was a brook 90 tiles away, and nothing told anybody.
-- Runs 7-9 (FR-31/33a/34/47): patients died of thirst in wards next to full drink stores, because a Water
-- Source zone on 1/7 seepage does not count for the game: GiveWater was cancelled "No water source".
--   * patients: citizens (census ids) who need health care (unit sheet "needs health care", the
--     injured notification) or lie resting in bed; their thirst timer is watched. A patient over
--     thirst_alarm (30,000, FR-34) wakes the LLM (DECISION_NEEDED patient_thirst, A) with the cause and a
--     one-line recipe (dry hospital: delete the hospital zone or carry water), the caregivers (citizens with
--     FEED_WATER_CIVILIANS) and the buckets: one line for all such patients, at once when one crosses the
--     alarm, else weekly;
--   * water sources, the game's own condition (FR-33a/34): a built well with revealed water down its shaft,
--     or an active Water Source zone with a revealed water tile of depth >= deep (4/7) on the zone's own
--     level (zone_below: also the level below; off, a brook top is unconfirmed live). Shallow water and the
--     mere presence of water tiles do not count. A hospital is served when such a source lies within `near`
--     tiles of its zone; the refuge when a wet well stands on a Tiefe+ tile;
--   * hospital gate (FR-31/34): a hospital location (or a pending `hospital` project) without an accepted
--     source wakes the LLM (HOSPITAL_DRY, A) with a one-line recipe from the water-source scan, when the
--     dry episode starts, then only when a patient joined or a new cause appeared, not before max(a week with
--     patients, else a month, 10 min wall clock) (BUG-008); the run that already sent patient_thirst sends
--     none. A `cistern` is asked monthly (PROJECT_REQUEST, B; bp sites cistern);
--   * water sources scan (FR-47, `inspect what=water_sources`): revealed water of depth >= deep around the
--     hospitals (else the citizens), `near` tiles wide and ws_dz levels up and down, through snapshot.liquids
--     (sliced, after the run's decisions); per water body its level, size, depth, an accepted zone or well
--     over it, a standable bank reachable from the citizens (snapshot.reach), else the shortest dig through
--     revealed natural wall on that level to such a bank. Run on request, and weekly while the hospital
--     gate is dry or no accepted water exists (BUG-288: a slice in every step, at most ws_slices + ws_body_slices; BUG-289:
--     boxes round every citizen and the remembered bodies, a lattice survey of the surface levels; BUG-290: a pit open above
--     the water is a well spot; BUG-291: a revealed aquifer tile beside the water marks its level). Hidden tiles are never read. BUG-031: cavern water (a revealed cavern tile in the body) is
--     listed (`cavern` 1) but never offered: caverns stay sealed; a cistern room of the manifest is named with
--     what it lacks (no well, its well over 0/7, out of reach) instead of "a cistern";
--   * buckets (bucket-delivery fallback: caregivers carry water from any well or Water Source zone in a free
--     bucket): want = max(the hospital's desired buckets, buckets_min) + 1 per patient (<= buckets_max).
--     Forbidden buckets on revealed Kern+ tiles are unforbidden (item_flag; not in BREACH, and without a Kern+
--     burrow only in PEACE), and a missing rest is ordered (workorder dfllm:bucket, MakeBucket in wood, one
--     live order at a time). Items are kept as ids between frames and looked up again before a write;
--   * pond loop (live L6, Paddletribes): a Pond zone beside a WET well makes the carriers take the water from that
--     very well (the nearest source) and pour it into the pond hole over the same sump, again and again. A Pond
--     zone within `pond_near` tiles of a wet well is removed (act.pond_remove) unless a wet Water Source zone
--     is the real supply; at most `pond_per_run` a run;
--   * cisterns (manifest rooms tpl `cistern`): revealed water on the well room floor (2 tiles, or 1 tile in
--     two runs in a row) means the pipe is flooding the room: DECISION_NEEDED cistern_flood (A), close the
--     floodgate with the room's lever;
--   * dry cisterns (BUG-040, Run 11 y453: the cisterns y450s0b0 and y452s1b0 were done, their wells never wet): a
--     manifest cistern room (merged when its project is done) whose built well stays dry for cistern_dry_days is
--     reported once per dry spell (CISTERN_DRY, B) with what should fill it: its pond zone (bucket-fed), a pond zone this
--     module removed as a loop, its pipe's floodgate lever, or nothing; the nearest accepted water to carry from;
--   * the sources' burrows (BUG-040): each source is labelled with Kern+ or the refuge when it stands on it (state
--     water.src_l, M.label for readiness's texts); M.wet_wells(name) tells seal how many wells of a burrow are wet
--     (seal.refuge_drink reports them: a dry cistern's well is no drink for the refuge; readiness's refuge_dry already
--     counts only wet ones through refuge_ok);
--   * dry hospital removal (BUG-034, Run 11): while a patient's thirst is over patient_thirst (25,000), every zone of
--     a hospital location none of whose zones is served is removed (act.hospital_remove, the zones screen), at most
--     remove_per_run a run; a location with one served zone keeps all of them. HOSPITAL_REMOVED (A) names the zones,
--     the locations and the patients; a day later kern.log says how many GiveWater jobs run (see remove_dry).
--   * BUG-103: patients and caregivers are citizens (isCitizen); the census also holds residents, who are neither;
--   * BUG-104: a patient over the alarm gets a verdict on why no GiveWater job runs (M.give_diag: alert / noreach / stuck / open /
--     nojob / run, BUG-324: nowater, with the job, caregiver and bucket counts); `added` of patient_thirst counts caregivers put into the Orderlies
--     detail, never jobs (the kernel creates none); BUG-343: `run` for M.NOEFFECT_DAYS while the same patient's thirst
--     only climbs is `noeffect` (M.give_effect), and PATIENT_DYING's `lie` says why he lies (M.lie: wounds, counters,
--     liquid, hunger, syndromes); BUG-344: M.drink_fix tells economy's thirst decision which well a thirsty citizen
--     stands at without drinking, or the recipe when no water is accepted (report only);
--   * BUG-507/508: a GiveWater / GiveFood / FillPond worker who has not moved for stall_days is stalled (M.stalls): off Orderlies for a
--     run, the pond zone beside him removed, from the third round the hospital zone of a patient over stall_dying removed; DECISION
--     job_stalled and the verb water.unstick (no job is ever removed);
--   * BUG-106: `inspect what=hospital` and the state's water.gaps list the gaps of the wound care (M.audit), once per run.
--   * BUG-131: a hospital zone outside the core that is idle or superseded does not count in hosp_out (M.hosp_sort); the
--     verb hospital.retire removes one such zone (the zones screen's remove, act.hospital_remove; M.verbs).
-- Fair play: reads citizens by census id (thirst, health flags, current job, position, labors), buildings.other
-- vectors (WELL, ZONE_WATER_SOURCE or ANY_ZONE), items.other.BUCKET (flags, position, whether a bucket still
-- holds water: such a bucket is no free bucket), manager orders, site locations, burrow
-- membership; tiles only through snapshot.tile (revealed only). Never edits units or jobs; zones only through act
-- (a Pond zone beside a wet well, the zones of a dry hospital: the zones screen's remove).
-- Writes only through K.act, and only acts whose contract owners list `water` (item_flag, workorder, pond_remove,
-- hospital_remove, water_zone, work_detail, BUG-330: burrow_tiles for the care burrow Pflege+; the module also runs before
-- such a contract change, reporting what it would do instead).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local CAD = require('dfllm.util.cadence')   -- BUG-008: when a standing class-A condition is announced again
local WHO = require('dfllm.util.who')       -- BUG-103: a citizen of the player (the census also holds residents)

local M = {name = 'water', every = {ticks = 1200}, on = {}, verbs = {}}
local DAY = C.TICKS.DAY

-- Wake cadence (review): one patient_thirst line per patient every 3 game days came about every 8 s at 450
-- ticks/s and buried every other DECISION_NEEDED of a wake under water lines. Now one line covers all patients
-- over the alarm, at once when a patient crosses it, else weekly (care's mood re-wake); HOSPITAL_DRY starts
-- with the dry episode and repeats weekly with patients (monthly without), never in a run that sent
-- patient_thirst.
M.DEFAULTS = {
  thirst_alarm = 30000, thirst_watch = 25000, near = 30, shaft = 12, pond_near = 3, pond_per_run = 2,
  buckets_min = 2, bucket_per_patient = 1, buckets_max = 8, unforbid_per_run = 4,
  alarm_every = 7 * DAY, hosp_every = 7 * DAY, request_every = 28 * DAY, flood_every = 2 * DAY, flood_tiles = 2,
  units_per_slice = 40, items_per_slice = 200, zone_tiles = 25, order_backoff = 3 * DAY,
  deep = 4, zone_below = false, gate_every = 28 * DAY, wake_wall_s = 600,
  -- BUG-537 (Run 16c i3 Sealcertain: HOSPITAL_DRY ~10 times a year beside a well that read 3/7 and 1/7 in turn): the dry episode ends
  -- only after the hospital has had accepted water for gate_clear ticks in a row; a flicker is the same episode
  gate_clear = 3 * DAY,
  -- BUG-537: DECISION_NEEDED hospital_supply (table, traction bench, splints, thread, cloth missing while a patient lies): again after
  hosp_sup_every = 28 * DAY,
  -- BUG-265 (Run 15 Earthboat: 6 bodies 10-29 tiles from the hospital, all reach 0): ws_dig 8 -> 16 walls (ws_reads still
  -- caps the tile reads per body)
  ws_dz = 3, ws_tiles = 1500, ws_every = 7 * DAY, ws_bodies = 12, ws_dig = 16, ws_reach = 6, ws_reads = 400,
  -- BUG-288 (Run 15 Inkintense: 'scan queued' a season long): a scan reads at most ws_read_max tiles in at most ws_slices
  -- read slices (>= ws_tiles a slice) and its bodies in at most ws_body_slices slices. BUG-289 (Drillchamber: the brook
  -- 141,67,143 outside the box): besides the hospital's (or the citizens' median) box, a ws_cit box round every citizen, a
  -- ws_mem_r box round each of the ws_mem bodies the last scans found, a survey of the whole map's surface levels (the
  -- surface at the reference column and the map centre, ws_survey_levels each, every ws_lattice-th tile, at most
  -- ws_survey_max tiles) and a ws_seed_r box round what the survey met (at most ws_seed_max tiles)
  -- (review: ws_lattice 5, not 3: with (x + 2y) % 3 a 1-tile brook running along x = y + k was never met)
  ws_read_max = 90000, ws_slices = 18, ws_body_slices = 4, ws_cit = 10, ws_mem = 8, ws_mem_r = 10,
  ws_survey_levels = 2, ws_lattice = 5, ws_survey_max = 36000, ws_seed_r = 10, ws_seed_max = 9000,
  -- BUG-290: a pit (open space right above water >= deep, a reachable floor beside it) counts as a well spot
  pit_well = true,
  -- BUG-034: a dry hospital's zones go once a patient is over patient_thirst (DF's "thirsty" mark is ~25,000-50,000;
  -- dehydration kills at ~75,000); hosp_remove false keeps them (report only, as before)
  patient_thirst = 25000, hosp_remove = true, remove_per_run = 8,
  -- BUG-040: a done cistern whose built well stays dry this many days is reported once (CISTERN_DRY, B)
  cistern_dry_days = 30,
  -- BUG-344 review (Run 15d Drillchamber: well 18324 over 1-2/7 gave no citizen water, 13 dead beside it): a well counts
  -- as accepted drink only over water >= well_min/7; shallower is 'shallow' (no source for hospital, refuge, served).
  -- DF's own line for a well is not documented in this repo (the Water Source zone's is 4/7, deep): 3 is conservative
  well_min = 3,
  -- BUG-425 (Run 16a i1 Manorsubtle: the fortcore wells read 1-2/7 and were never accepted, 13 of 15 died of thirst with no other
  -- water): when NO other source is accepted and no body of water has a bank the citizens reach, a built well over water of at least
  -- well_emerg/7 counts as a (slow) drink source, flagged `emerg`: it is no hospital source and not in the state's water.src (plan
  -- keeps asking for real water), and kern.log / the decision say so. 0 = never (only well_min wells count)
  well_emerg = 2,
  -- BUG-054 (Run 11 y497: 5 patients dead of thirst at once with 4 caregivers, 24-27 free buckets and "hospital ok"):
  -- caregivers (the FEED_WATER_CIVILIANS labor, the Orderlies work detail) scale with the patients: carers_per_patient
  -- each (at least carers_min while there is a patient, at most carers_max), carers_urgent more while a patient is over
  -- thirst_alarm; at most carers_per_run are added a run; the ones the kernel added leave after carers_hold_days without
  -- any patient (hysteresis). A patient over dying_thirst (60,000: death follows at ~75,000) is PATIENT_DYING (A), again
  -- only for news and not before dying_every ticks. carers_max 0 switches the scaling off.
  carers_per_patient = 1, carers_min = 2, carers_max = 8, carers_urgent = 2, carers_per_run = 2, carers_hold_days = 14,
  dying_thirst = 60000, dying_every = 2 * DAY,
  -- BUG-104: a GiveWater job that stood open (no worker) this many days is "stuck" in the cause text
  give_stuck_days = 2,
  -- BUG-434 (Run 16d i4 Mazelanterns y401: 11 died of thirst beside 272 days of barrel drink, 8 patients over 60,000, no hospital
  -- zone, the only accepted water a zone 83-101 tiles away): GiveWater needs water, not a hospital zone (kern.log showed GiveWater
  -- jobs with 'hospital none'), and barrels are no water. A patient over thirst_watch whose nearest accepted source (a wet well or
  -- Water Source zone, no emergency well) is farther than patient_far tiles, or with none at all, is a PROJECT_REQUEST cistern
  -- why=patient_water (at most every request_every, none while a cistern project is pending) and the GiveWater verdict names the
  -- distance. 0 = off
  patient_far = 40,
  -- BUG-383 (Run 16b i2 y381: unit 26275 died of thirst at 75,001 with '1 GiveWater job running 25+ days without effect'): a
  -- `noeffect` verdict releases the carriers of the running GiveWater jobs from the Orderlies detail for one run (at most
  -- restale_max of them, again after restale_every) so the game drops the stale job and posts a new one; restale false: off
  restale = true, restale_max = 2, restale_every = 2 * DAY,
  -- BUG-507/508 (Run 16b i2 Brotherarrow y386: a child hung 26 days in a GiveWater job at a dry well while the patient died of
  -- thirst; the captain hung in FillPond there at thirst 53,360): a water job (GiveWater, GiveFood, FillPond) whose worker has
  -- not moved for stall_days, with the worker over stall_need thirst (or DF's hungry line), or a patient over thirst_alarm for
  -- a Give job, is stalled (M.stalls). Each stalled worker gets a round at most every stall_every, stall_max workers a run:
  -- he leaves the Orderlies detail for a run, a Pond zone within pond_near of him goes (the zones screen's remove), and from
  -- the third round (stall_hosp) the hospital zone of a patient over stall_dying goes (BUG-034's recipe). stall false: report only
  stall = true, stall_days = 3, stall_need = 25000, stall_every = DAY, stall_max = 2, stall_hosp = true, stall_dying = 45000,
  -- BUG-539 (Run 16b i2: water.unstick removed the hospital zone and nothing drew it again for 15+ days): a zone this module
  -- removed (remove_dry, stall_hospital) is remembered (p.hrm) and drawn again at its old location by M.restore: a stall zone
  -- once restore_wait passed and no patient is over patient_thirst (at the latest after restore_max), a dry zone as soon as an
  -- accepted source is within near of it. hosp_restore false: only the verb hospital.restore
  hosp_restore = true, restore_wait = DAY // 2, restore_max = 5 * DAY,
  -- BUG-540 (the verifier of BUG-539: a 'dry' entry had no timeout, blocked bp sites hospital for good and hospital.restore on it
  -- flapped with remove_dry): an entry older than hrm_expire is forgotten; a dry one is neither drawn again (the verb refuses)
  -- nor counted as a block for a new site while no accepted water stands within near of the old room
  hrm_expire = 20 * DAY,
  -- BUG-541 (Run 16b i2 y386/y390, Run 16d i4 y404: 3 patients dead, the GiveWater carriers stood 26-28 days at a DRY well beside
  -- the hospital instead of filling at the pond zone): a GiveWater worker who has stood trap_days within trap_near tiles of a
  -- built well with no water below it while a patient is over thirst_watch is a case at once (no stall_need, no stall_days); the
  -- DECISION dry_well names the well and `well.retire`; from the second round the zone of a patient over trap_dying goes (the
  -- game's own recipe: he then fetches his own drink). trap false: off
  trap = true, trap_days = 1, trap_near = 2, trap_dying = 35000,
  -- BUG-325: the scan asks the walk from up to ws_from citizens (the nearest the reference); a tile is reachable from any
  ws_from = 3,
  -- BUG-324: while no water is accepted, the kernel zones the scan's best reachable, safe water as a Water Source (wz false:
  -- off), at most one zone every wz_every and wz_max spots within wz_forget (a spot tried is not tried again before)
  wz = true, wz_every = 2 * DAY, wz_max = 4, wz_forget = 28 * DAY,
  -- BUG-330: while the civ alert sounds, a patient over care_thirst outside every alert burrow with no visible hostile within
  -- care_near tiles gets his tile, the nearest accepted water and a free bucket painted into the care burrow M.CARE, which
  -- siege lists in the alert (care false: off)
  care = true, care_thirst = 30000, care_near = 20,
  -- BUG-559 (Run 16b i2 Brotherarrow y402: 3 patients in a hospital on Kern+, outside the BREACH alert burrow Tiefe+, died of
  -- thirst beside 47 caregivers): in BREACH the care burrow opens too (care_breach false: never) when every painted tile lies
  -- on Kern+ and no visible hostile is within care_breach_near tiles of one (the census must be fresh and complete)
  care_breach = true, care_breach_near = 30,
  -- BUG-571 (Run 16b i2 Brotherarrow y406: patient 27722 died of thirst in a 115-day SIEGE, the only accepted water, the pond zone 17696 at
  -- 102,108,138, lay one level above Kern+ and care_safe wanted every tile on Kern+): in a SIEGE the care burrow may take a patient, water or
  -- bucket tile OUTSIDE Kern+ (care_siege_out false: never) when seal's entrance check says the fort is sealed (no route from the map
  -- edge to a citizen, after the last change), the tile lies on the citizens' own walk groups (snapshot.far: not outside the walls) and no
  -- visible hostile is within care_siege_near tiles of it (the census must be fresh and complete)
  care_siege_out = true, care_siege_near = 40,
  -- BUG-344: a citizen (no patient) at this thirst within 1 tile of an accepted well tells economy's thirst decision that
  -- the well gives him no water (M.drink_fix)
  well_thirst = 50000,
  -- BUG-446 (Run 16b i2 Roadvises, 16c i3 Castletongs: the embark scan said `brook=in`, the water scan met only a pond 72 tiles off or
  -- nothing, i2 ran out of drink): a brook (tiletype BROOK_BED / BROOK_TOP) lies under 1-3/7 of water, below `deep`. The scan reads
  -- brook tiles from brook_min/7 up (0 = off: only >= deep as before); such a body (`brook` 1) with a bank the citizens reach is a
  -- place to drink (water.drink_access), but no Water Source zone (the game wants 4/7) and no well spot: the recipe is a piped
  -- cistern to it
  brook_min = 1,
  -- BUG-446: water that is only reachable farther than drink_far tiles is no drink supply for a fort that has none of its own: with no
  -- accepted source, no brewable plant and drink under drink_far_d days economy asks DECISION_NEEDED no_water (0 = off)
  drink_far = 40, drink_far_d = 120,
  -- BUG-448 (Run 16d i4: aqshaft and cistern finished, the water scan 7.3 M ticks old): a finished aqshaft or cistern queues a
  -- scan at once and again ws_redo ticks later (the cistern fills; 0 = no second scan)
  ws_redo = 3 * DAY,
}
M.THIRSTY_MAX = 16                           -- BUG-344: thirsty citizens' positions kept a run
M.SRC_MAX = 8                                -- accepted sources in the state (water.src), nearest first
M.SRC_LBL = 4                                -- BUG-040: labels of the first ones (water.src_l: 'well 19098 in Kern+')
M.BUCKET_ORDER = {job = 'MakeBucket', material_category = {'wood'}, frequency = 'OneTime'}
local BUSY = {'in_job', 'trader', 'removed', 'garbage_collect', 'construction', 'in_building', 'hostile'}

local st = {}
local has_liquids, emit_gate             -- the hospital gate and the water sources scan (below)

local function fmt(n) return string.format('%d', math.tointeger(n) or -1) end
local function trunc(s, n) return #s > n and s:sub(1, n) or s end
local function vec(f)
  local ok, v = pcall(f)
  return ok and v or {}
end

-- config/baseline.json "water" tunes the defaults; a value of another type than its default is ignored (BUG-034: a
-- string thirst would fault every run; `python -m dfpilot.lint --config` names it)
function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.water
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  if type(c) == 'table' then
    for k, v in pairs(c) do
      if M.DEFAULTS[k] == nil or type(v) == type(M.DEFAULTS[k]) then r[k] = v end
    end
  end
  return r
end

-- the contract may not list water as an owner of an act yet (feature detection, no 'not owner' faults)
function M.can(fn)
  for _, o in ipairs(C.ACT[fn] or {}) do if o == 'water' then return true end end
  return false
end

local function pstate(K)
  local p = K.persist.get('m.water')
  if type(p) ~= 'table' then
    p = {v = 2}
    K.persist.set('m.water', p)
  end
  p.alarm = json.object(type(p.alarm) == 'table' and p.alarm or {})
  p.gj = json.object(type(p.gj) == 'table' and p.gj or {})      -- BUG-104: open GiveWater job id -> tick first seen
  return p
end

local function tile(K, x, y, z)
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  if ok and type(t) == 'table' then return t end
  return nil
end
local function wet_char(c) return c == 'w' or c == '~' end
local ROCK = {['#'] = true, S = true, C = true, F = true, T = true}     -- snapshot legend: walls, fortifications, trees

-- water under a well: the bucket goes down the open shaft (`_`) to the first water tile (a ramp or floor under
-- the hole holds the water itself and reads `w`/`~`); a dry ramp, rock, a floor or a hidden tile ends the
-- shaft. Without a tile reader nothing counts as wet. BUG-031 (Run 11: HOSPITAL_DRY monthly beside a cistern, the
-- recipe "a cistern"): the second value says what the shaft ends on, {at = {x, y, z}, flow = depth 0..7 (nil
-- unknown), why = 'water' | 'dry' (a floor or ramp without water) | 'rock' | 'hidden' | 'deep' (open space below the
-- shaft limit) | 'shallow' (BUG-344 review: water below `min`/7, default 1; without a depth 'w' is 1..3: shallow)},
-- for the HOSPITAL_DRY text
function M.well_wet(K, x, y, z, depth, min)
  min = min or 1
  local shal                                          -- merge16 review: the first shallow tile over open space
  for zz = z - 1, z - (depth or 12), -1 do
    local t = tile(K, x, y, zz)
    local at = {x, y, zz}
    if not t then return false, shal or {at = at, why = 'hidden'} end
    local f = math.tointeger(t.flow)
    if wet_char(t.c) then
      if (f and f < min) or (not f and t.c == 'w' and min > 1) then
        -- a thin layer in open space over deeper water (a cistern's or river's top) is not the bottom: look further
        -- down; shallow only when the shaft ends on it or nothing deeper is found
        shal = shal or {at = at, flow = f, why = 'shallow'}
        if t.shape ~= 'EMPTY' then return false, shal end
      else
        return true, {at = at, flow = f, why = 'water'}
      end
    elseif t.c ~= '_' then
      return false, shal or {at = at, flow = f or 0, why = ROCK[t.c] and 'rock' or 'dry'}
    end
  end
  return false, shal or {at = {x, y, z - (depth or 12)}, why = 'deep'}
end

-- water the game accepts in a Water Source zone (FR-33a/34): a revealed tile of depth >= deep, never magma.
-- snapshot.tile gives the depth (flow); a reader without it marks depth 4..7 as '~' and 1..3 as 'w'
function M.deep_tile(t, c)
  if type(t) ~= 'table' or t.magma == true then return false end
  local f = math.tointeger(t.flow)
  if f ~= nil then return f >= c.deep end
  return t.c == '~'
end

-- a zone tile of deep water on the zone's own level (zone_below: or on the level below, e.g. a brook bed)
local function zone_wet(K, c, zn)
  local n = 0
  for y = zn.y1, zn.y2 do
    for x = zn.x1, zn.x2 do
      n = n + 1
      if n > c.zone_tiles then return false end
      for dz = 0, c.zone_below == true and 1 or 0 do
        if M.deep_tile(tile(K, x, y, zn.z - dz), c) then return true end
      end
    end
  end
  return false
end

local function hospital_locations()
  local out = {}
  local ok = pcall(function()
    local site = dfhack.world.getCurrentSite()               -- Lua API.txt:2205
    local htype = df.abstract_building_type.HOSPITAL
    for _, l in ipairs(site and site.buildings or {}) do
      if l:getType() == htype then out[l.id] = l end
    end
  end)
  return ok and out or {}
end

local function desired_buckets(loc)
  local ok, n = pcall(function() return loc.contents.desired_buckets end)
  return ok and math.tointeger(n) or nil
end

local function burrow(K, role, default)
  local name = default
  for n, b in pairs(K.manifest().burrows or {}) do if b.role == role then name = n end end
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)   -- Lua API.txt:2412
  return ok and b or nil, name
end

local function burrow_named(name)
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)
  return ok and b or nil
end

-- BUG-153 (live i4): the burrows the sounding civ alert holds the citizens in, read from the game
-- (plotinfo.alerts.list[idx].burrows, as the alerts screen shows them): {{n = name, b = burrow}}; {} when unreadable.
-- give_diag asks it when siege's list (runtime memory) is empty: after a reload or for an alert the player raised
function M.alert_burrows(idx, nocare)
  local out = {}
  pcall(function()
    local ids = {}
    for _, id in ipairs(df.global.plotinfo.alerts.list[idx].burrows) do ids[id] = true end
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
      if ids[b.id] and not (nocare and b.name == M.CARE) then out[#out + 1] = {n = tostring(b.name), b = b} end
    end
  end)
  return out
end

local function on_burrow(b, x, y, z)
  if not b or not x then return false end
  local ok, yes = pcall(function() return dfhack.burrows.isAssignedTile(b, {x = x, y = y, z = z}) end)
  return ok and yes == true
end

local function dist_box(x, y, z, b)            -- Chebyshev distance from a tile to a zone rect (b.z only)
  local dx = x < b.x1 and b.x1 - x or (x > b.x2 and x - b.x2 or 0)
  local dy = y < b.y1 and b.y1 - y or (y > b.y2 and y - b.y2 or 0)
  return math.max(dx, dy, math.abs(z - b.z))
end

---------------------------------------------------------------- phases
-- patients (citizens by census id)
local function patient(u)
  local ok, yes = pcall(function()
    if u.health and u.health.flags.needs_healthcare then return true end   -- notifications.lua:172
    local j = u.job and u.job.current_job
    return j ~= nil and j.job_type == df.job_type.Rest                    -- full-heal.lua:209
  end)
  return ok and yes == true
end

-- a caregiver who carries water to the bedridden: an adult with the FEED_WATER_CIVILIANS labor (labors screen)
local function carer(u)
  local ok, yes = pcall(function()
    return not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
           and u.status.labors[df.unit_labor.FEED_WATER_CIVILIANS] == true
  end)
  return ok and yes == true
end

-- BUG-034: a citizen carrying water to a patient now (current job GiveWater, the unit sheet's job line "Give water";
-- GiveWater2 where the enum has it): the run's count tells whether the game posts and keeps such jobs (the DF rule
-- HOSPITAL_REMOVED rests on)
local function giving(u)
  local ok, yes = pcall(function()
    local j = u.job and u.job.current_job
    if j == nil then return false end
    for _, name in ipairs({'GiveWater', 'GiveWater2'}) do
      local t = df.job_type[name]
      if t ~= nil and j.job_type == t then return true end
    end
    return false
  end)
  return ok and yes == true
end

local function phase_units(K, c, r)
  local n = 0
  while r.idx < #r.ids and n < c.units_per_slice do
    r.idx, n = r.idx + 1, n + 1
    local id = r.ids[r.idx]
    local u = df.unit.find(id)
    if u and not WHO.citizen(u) then
      -- BUG-103 (Run 14 note 74): the census holds the fort's residents too; a resident, a merchant or a visitor is no
      -- patient of ours (thirst alarms, the dry hospital's removal) and no caregiver (the Orderlies detail asks citizens)
      r.outsiders = r.outsiders + 1
    elseif u and patient(u) then
      local th, hu = 0, 0
      pcall(function() th = math.tointeger(u.counters2.thirst_timer) or 0 end)
      pcall(function() hu = math.tointeger(u.counters2.hunger_timer) or 0 end)    -- BUG-343: fed either?
      local x, y, z = dfhack.units.getPosition(u)
      r.patients[#r.patients + 1] = {id = id, thirst = th, hunger = hu, x = x, y = y, z = z}
    elseif u then
      if #r.thirsty < M.THIRSTY_MAX then                   -- BUG-344: where the thirsty citizens stand (M.drink_fix)
        local th = 0
        pcall(function() th = math.tointeger(u.counters2.thirst_timer) or 0 end)
        if th >= c.well_thirst then
          local x, y, z = dfhack.units.getPosition(u)
          if x then r.thirsty[#r.thirsty + 1] = {id = id, thirst = th, x = x, y = y, z = z} end
        end
      end
      local is_carer = carer(u)
      if is_carer then
        r.carers[#r.carers + 1] = id
        local idle = M.idle(u)
        if idle then r.carers_idle = r.carers_idle + 1 end
        if #r.cpos < M.POOL_MAX then                       -- BUG-104: where the caregivers stand (the reach test)
          local x, y, z = dfhack.units.getPosition(u)
          if x then r.cpos[#r.cpos + 1] = {x = x, y = y, z = z, idle = idle} end
        end
      end
      if giving(u) then r.give = r.give + 1 end
      M.medic_count(r, u)                                  -- BUG-106: who holds the wound care labors
      if #r.home < 60 then
        local x, y, z = dfhack.units.getPosition(u)
        if x then r.home[#r.home + 1] = {x = x, y = y, z = z} end
      end
      -- BUG-054: who the kernel could ask to carry water (not a caregiver yet; at most POOL_MAX; M.carers asks
      -- M.carer_ok only for the ones it would pick, and only when it needs more caregivers)
      if not is_carer and #r.pool < M.POOL_MAX then
        local x, y, z = dfhack.units.getPosition(u)
        if x then r.pool[#r.pool + 1] = {id = id, x = x, y = y, z = z, idle = M.idle(u)} end
      end
    end
  end
  return r.idx >= #r.ids
end

-- BUG-425: the emergency drink wells (see DEFAULTS well_emerg): when nothing else is accepted (no wet zone or well) and the last scan
-- knows no body with a bank the citizens reach, the shallow built wells over water >= well_emerg/7 become sources flagged `emerg`.
-- An unknown scan accepts nothing on a guess; a well a citizen over well_thirst stands beside (`thirsty`) is no source: the trickle
-- demonstrably does not reach him (`emerg_no` = his thirst). Returns the wells made sources
function M.emerg_wells(c, sources, ws, thirsty)
  local out = {}
  local mn = math.tointeger(c.well_emerg) or 0
  if mn <= 0 or not ws then return out end
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern ~= 1 and b.bank then return out end
  end
  for _, s in ipairs(sources) do if s.wet then return out end end
  for _, s in ipairs(sources) do
    local bl = s.below
    if s.kind == 'well' and s.built ~= false and bl and bl.why == 'shallow' and (math.tointeger(bl.flow) or 0) >= mn then
      -- proof against it (Run 15d: a citizen beside a 1-2/7 well went on thirsting, 13 dead): one standing at it over well_thirst
      local proof
      for _, t in ipairs(thirsty or {}) do
        if t.z == s.z and math.max(math.abs(t.x - s.x), math.abs(t.y - s.y)) <= 1 then proof = t; break end
      end
      if proof then s.emerg_no = proof.thirst else s.wet, s.emerg = true, true; out[#out + 1] = s end
    end
  end
  return out
end

-- wells, Water Source zones, hospital zones
local function phase_sites(K, c, r)
  local other = df.global.world.buildings.other
  for _, w in ipairs(vec(function() return other.WELL end)) do
    local done = true
    pcall(function() done = w:getBuildStage() >= w:getMaxBuildStage() end)
    local wet, info = false, nil
    if done then wet, info = M.well_wet(K, w.x1, w.y1, w.z, c.shaft, c.well_min) end   -- BUG-344 review: well_min
    r.sources[#r.sources + 1] = {kind = 'well', id = w.id, x = w.x1, y = w.y1, z = w.z, wet = wet,
                                 built = done, below = info,                  -- BUG-031: what the shaft ends on
                                 chain = not done and M.chain_wait(w) or nil} -- BUG-264: its job waits for a chain
  end
  local locs = hospital_locations()
  r.locs_total = 0
  for _ in pairs(locs) do r.locs_total = r.locs_total + 1 end
  local wsrc = df.civzone_type and df.civzone_type.WaterSource
  local zones, seen = {}, {}                                 -- a Lua list: never write into a DF vector
  for _, zn in ipairs(vec(function() return other.ZONE_WATER_SOURCE end)) do
    zones[#zones + 1] = zn
    seen[zn.id] = true
  end
  local any = vec(function() return other.ANY_ZONE end)
  local pondt = df.civzone_type and df.civzone_type.Pond
  for _, zn in ipairs(any) do
    if pondt and zn.type == pondt then
      r.ponds[#r.ponds + 1] = {id = zn.id, x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = zn.z}
    end
    if locs[zn.location_id] then
      r.hosp[#r.hosp + 1] = {id = zn.id, x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = zn.z,
                             want = desired_buckets(locs[zn.location_id]), loc = zn.location_id}
    end
    if wsrc and zn.type == wsrc and not seen[zn.id] then zones[#zones + 1] = zn; seen[zn.id] = true end
  end
  local has_zone = {}
  for _, h in ipairs(r.hosp) do has_zone[h.loc] = true end
  r.orph = {}                                                -- BUG-540: hospital locations without a zone (ids, ascending)
  for id in pairs(locs) do if not has_zone[id] then r.orph[#r.orph + 1] = id end end
  table.sort(r.orph)
  for _, zn in ipairs(zones) do
    local active = true
    pcall(function() active = zn.spec_sub_flag.active end)
    if active then
      r.sources[#r.sources + 1] = {kind = 'zone', id = zn.id, x = (zn.x1 + zn.x2) // 2, y = (zn.y1 + zn.y2) // 2,
                                   z = zn.z, wet = zone_wet(K, c, zn), box = {x1 = zn.x1, y1 = zn.y1, x2 = zn.x2,
                                                                                y2 = zn.y2, z = zn.z}}
    end
  end
  local em = M.emerg_wells(c, r.sources, st.ws, r.thirsty)
  if #em > 0 then
    local p = pstate(K)
    p.emg = json.object(type(p.emg) == 'table' and p.emg or {})
    for _, s in ipairs(em) do
      if not p.emg[tostring(s.id)] then
        p.emg[tostring(s.id)] = K.now().tick
        K.log('warn', 'water: EMERGENCY: no other drink source, well %d at %d,%d,%d over only %d/7 (< well_min %d/7) is accepted as a '
              .. 'slow drink source (well_emerg %d): dig or pipe real water', s.id, s.x, s.y, s.z, s.below.flow or 0, c.well_min,
              c.well_emerg)
      end
    end
  end
  return true
end

-- buckets: usable, free, forbidden inside Kern+
local function item_pos(it)
  local a, b, c = dfhack.items.getPosition(it)               -- Lua API.txt:2055
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end

-- a bucket that still holds something (water dropped with an interrupted job) serves no other job until
-- fix/dry-buckets empties it (tools/fix/dry-buckets.txt; control-panel default: weekly). The item sheet shows it
local function holds(it)
  local ok, l = pcall(dfhack.items.getContainedItems, it)          -- Lua API.txt:2043
  return ok and type(l) == 'table' and #l > 0
end

local function phase_buckets(K, c, r)
  local v = vec(function() return df.global.world.items.other.BUCKET end)
  local n = 0
  while r.idx < #v and n < c.items_per_slice do
    local it = v[r.idx]
    r.idx, n = r.idx + 1, n + 1
    local f = it and it.flags
    if f and not f.removed and not f.garbage_collect and not f.trader then
      r.buckets = r.buckets + 1
      local busy = false
      for _, k in ipairs(BUSY) do if f[k] then busy = true end end
      if not busy and holds(it) then
        r.full = r.full + 1
      elseif not busy and not f.forbid and not f.dump then
        r.free = r.free + 1
        if #r.bpos < 20 then                     -- BUG-330: where free buckets lie (the care burrow takes the nearest)
          local x, y, z = item_pos(it)
          if x then r.bpos[#r.bpos + 1] = {x = x, y = y, z = z} end
        end
      elseif not busy and f.forbid then
        r.forbidden[#r.forbidden + 1] = it.id       -- an id: the item may be gone before the run finishes
      end
    end
  end
  return r.idx >= #v
end

---------------------------------------------------------------- decisions
local function served(K, c, r, h)
  local best
  for _, s in ipairs(r.sources) do
    if s.wet and not s.emerg then                       -- BUG-425: an emergency well is no hospital water
      local d = dist_box(s.x, s.y, s.z, h)
      if not best or d < best.d then best = {d = d, s = s} end
    end
  end
  return best and best.d <= c.near, best
end

local function order_live(id)
  if math.type(id) ~= 'integer' then return false end
  local ok, live = pcall(function()
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then return (o.amount_left or 0) > 0 end
    end
    return false
  end)
  return ok and live == true
end

-- a forbidden bucket that may be unforbidden now: still there and forbidden (the scan ran over several frames:
-- the item is looked up again by id, never kept as a pointer), on a revealed tile inside Kern+. Not in BREACH
-- (an enemy is inside Kern+); without a Kern+ burrow only in PEACE (care's inside() rule)
local function unforbid_ok(K, kern, id)
  local it = df.item.find(id)
  local f = it and it.flags
  if not f or not f.forbid or f.removed or f.garbage_collect or f.trader then return false end
  for _, k in ipairs(BUSY) do if f[k] then return false end end
  local x, y, z = item_pos(it)
  if not x then return false end
  local mode = K.mode()
  if mode == 'BREACH' or (not kern and mode ~= 'PEACE') then return false end
  if kern and not on_burrow(kern, x, y, z) then return false end
  return tile(K, x, y, z) ~= nil
end

local function supply_buckets(K, c, r, p, want)
  local fixed, ordered = 0, 0
  local kern = burrow(K, 'kern', 'Kern+')
  if r.free < want and M.can('item_flag') then
    for _, id in ipairs(r.forbidden) do
      if r.free + fixed >= want or fixed >= c.unforbid_per_run then break end
      if unforbid_ok(K, kern, id) and K.act.item_flag(id, 'forbid', false) then fixed = fixed + 1 end
    end
  end
  local missing = want - r.free - fixed
  local now = K.now().tick
  if missing > 0 and M.can('workorder') and not order_live(p.order) and now >= (p.order_retry or 0) then
    local spec = {}
    for k, val in pairs(M.BUCKET_ORDER) do spec[k] = val end
    spec.material_category = {'wood'}
    spec.tag, spec.amount_total = 'dfllm:bucket', missing
    local ok, id = K.act.workorder(spec)
    if ok then p.order, ordered = id, missing else p.order_retry = now + c.order_backoff end
  end
  return fixed, ordered, missing
end

-- pond zones beside a wet well (see the header): the carriers would pour the well's own water back into it. BUG-040:
-- each removal is kept (p.prm, the last 8: id, rect centre, tick): a cistern's pond removed this way is named in
-- CISTERN_DRY (once its own well was wet the carriers took from it: a bucket-fed cistern cannot fill past that)
local function pond_loops(K, c, r, p)
  if #r.ponds == 0 or not M.can('pond_remove') then return 0 end
  for _, s in ipairs(r.sources) do
    if s.kind == 'zone' and s.wet then return 0 end            -- a real supply exists: the pond is no loop
  end
  local n = 0
  for _, pd in ipairs(r.ponds) do
    if n >= c.pond_per_run then break end
    for _, s in ipairs(r.sources) do
      if s.kind == 'well' and s.wet and dist_box(s.x, s.y, s.z, {x1 = pd.x1, y1 = pd.y1, x2 = pd.x2, y2 = pd.y2,
                                                                 z = pd.z}) <= c.pond_near then
        if K.act.pond_remove(pd.id) then
          n = n + 1
          K.log('warn', 'water: pond zone %d removed: the wet well %d beside it was its water source (a loop)',
                pd.id, s.id)
          p.prm = type(p.prm) == 'table' and p.prm or json.array{}
          p.prm[#p.prm + 1] = json.array{pd.id, (pd.x1 + pd.x2) // 2, (pd.y1 + pd.y2) // 2, pd.z, K.now().tick}
          while #p.prm > 8 do table.remove(p.prm, 1) end
          M.loop_mark(p, s.id, pd.id)                        -- BUG-263: its water is a store, no source
        end
        break
      end
    end
  end
  return n
end

---------------------------------------------------------------- BUG-263: a well fed only by its own pond
-- Run 15 Drillchamber y373: status said 'src 1 (well 17813 at 91,70,136 in Tiefe+)', bp sites hospital placed the
-- hospital beside it, then pond_loops removed pond zone 17822 ('the wet well 17813 beside it was its water source (a
-- loop)'), the well ran dry and HOSPITAL_DRY said 'no accepted water on the map' 13 days after the placement. The
-- acceptance (any water down the shaft) and the loop rule (pond_loops) disagreed in time. Now one predicate: a wet well
-- with a Pond zone within pond_near while no wet Water Source zone exists (the very case pond_loops calls a loop), or
-- one whose pond pond_loops removed (p.lw: well id -> {pond}; forgotten once the well reads dry), holds a store the
-- carriers poured from itself, no source: it is not accepted (s.wet false, s.loop = the pond id, s.water true). The
-- state's water.src (what bp sites hospital ranks by), served(), the gate and the removal all read s.wet; the refuge's
-- drink (refuge_ok, wet_wells: a store is drink for a siege) and CISTERN_DRY read s.water (the water that is there).
function M.loop_mark(p, wid, pond)
  p.lw = json.object(type(p.lw) == 'table' and p.lw or {})
  local k = fmt(wid)
  if type(p.lw[k]) ~= 'table' then p.lw[k] = {pond = pond} end
end

function M.loops(K, c, r, p)
  p.lw = json.object(type(p.lw) == 'table' and p.lw or {})
  local zone_wet = false
  for _, s in ipairs(r.sources) do if s.kind == 'zone' and s.wet then zone_wet = true end end
  local n = 0
  for _, s in ipairs(r.sources) do
    s.water = s.wet
    if s.kind == 'well' then
      local k = fmt(s.id)
      if not s.wet then
        p.lw[k] = nil                                         -- dry: a refill from elsewhere is judged anew
      else
        local pond
        for _, pd in ipairs(zone_wet and {} or r.ponds) do
          if dist_box(s.x, s.y, s.z, {x1 = pd.x1, y1 = pd.y1, x2 = pd.x2, y2 = pd.y2, z = pd.z}) <= c.pond_near then
            pond = pd.id
          end
        end
        if pond then M.loop_mark(p, s.id, pond) end
        local rec = p.lw[k]
        if type(rec) == 'table' then
          s.wet, s.loop, n = false, math.tointeger(rec.pond) or pond or -1, n + 1
        end
      end
    end
  end
  return n
end

-- the loop wells of the last run as one cause ('well 17813 at 91,70,136 is fed only by its own pond 17822 (a loop, no
-- outside supply)'), nil without one
function M.loop_cause(r)
  for _, s in ipairs(r.sources) do
    if s.loop then
      return string.format('well %d at %d,%d,%d is fed only by its own pond %d (a loop, no outside supply)', s.id, s.x, s.y,
                           s.z, s.loop)
    end
  end
end

---------------------------------------------------------------- water sources (FR-47)
-- Run 9: the aquifer probe pool (6-7/7) was walled in, the shaft below got a 1/7 trickle, and nobody knew where
-- deep water could be reached. The scan reads revealed water of depth >= deep through snapshot.liquids (hidden
-- tiles never), groups it into bodies per level and looks for a standable bank the citizens reach, else the
-- shortest dig through revealed natural wall on that level. Plain values only; sliced over frames.
local STAND = {['.'] = true, r = true, ['<'] = true, ['>'] = true, X = true, w = true, ['^'] = true}
local DIGGABLE = {['#'] = true, S = true}                 -- natural wall (smoothed too); constructions stay
local N8 = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

local function k3(x, y, z) return string.format('%d,%d,%d', x, y, z) end

local function median(list, f)
  local v = {}
  for _, e in ipairs(list) do v[#v + 1] = e[f] end
  table.sort(v)
  return v[(#v + 1) // 2]
end

has_liquids = function(K)
  local ok = K.call('snapshot', 'liquids', 0, 0, -1, -1, 0, 1)
  return ok == true
end

emit_gate = function(K, c, a)
  -- BUG-266: the first alarm waited for the scan: the dry well's fill source comes from it
  if a.dw and st.src then
    local new = M.dry_well(K, c, {sources = st.src})
    local i, j = a.why:find(a.dw, 1, true)
    if new and i then
      a.why = a.why:sub(1, i - 1) .. new .. a.why:sub(j + 1)
      if a.lost == a.dw then a.lost = new end
    end
  end
  local fix = M.recipe(c, a.cis, K)
  -- BUG-263: the first reason why there is none (a dropped source, a loop well, a dry sump) before the recipe
  K.emit('HOSPITAL_DRY', 'A', trunc(string.format('%s without accepted water, %d patient(s)%s: %s',
                                                  a.planned and 'planned hospital' or 'hospital', a.patients,
                                                  a.lost and (' (' .. a.lost .. ')') or '', fix), 200),
         {why = trunc(a.why, 200), patients = a.patients, zone = a.zone, near = c.near, recipe = trunc(fix, 200),
          cistern = a.cis and trunc(a.cis.txt, 120) or nil})
end

-- whether the kernel removes a dry hospital's zones itself (BUG-034): config and the contract owner
local function removes(c) return c.hosp_remove ~= false and M.can('hospital_remove') end

-- the one-line recipe of the hospital gate from the last scan: zone a reachable bank, else the shortest dig,
-- else a cistern; deleting the hospital zone lets the patients fetch their own drink meanwhile. BUG-031: with a
-- cistern room standing (`cis`, cistern_state), not "a cistern" but what that one lacks. BUG-034: the kernel deletes
-- the zones itself once a patient is over patient_thirst, so the tail says when instead of asking for it
-- BUG-262 (Run 15 Inkintense, Guildcleans: no brook, a light aquifer, 'hospital held back' for good): with an aquifer level
-- known (manifest aquifer_levels) and nothing better, an aquifer well (a cistern with p.water aquifer: its basin dug into
-- the aquifer level, the walls kept rough, no pond). BUG-265 (Run 15 Earthboat: 6 bodies 10-29 tiles away, reach 0): a body
-- within `near` without a bank or a dig gets a piped cistern to it instead of "a cistern"
-- bare (BUG-344): without the hospital's tail. nodig (BUG-344 review: economy's thirst decision): no 'dig ... to bare
-- the water' (digging at water is the player's, only after the PLAYBOOK's water checks): a body reached only by a dig
-- takes the later ways (a piped cistern, an aquifer well, a cistern)
function M.recipe(c, cis, K, bare, nodig)
  local ws = st.ws
  local tail = bare and '' or removes(c) and string.format('; until then the kernel removes it at thirst %d',
                                                            c.patient_thirst) or '; until then delete the hospital zone'
  local aqz = K and M.aq_level(K)
  local aq = aqz and string.format('an aquifer well (dfllm bp sites cistern water=aquifer: its basin on aquifer level z%d)',
                                   aqz) or nil
  if not ws then
    if cis then return cis.fix .. tail end
    return string.format('a well over water or a Water Source zone on water >= %d/7 within %d tiles (inspect '
                         .. 'water_sources)%s%s', c.deep, c.near, aq and (', or ' .. aq) or '', tail)
  end
  local best, cav, pit, brk
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern == 1 and b.d <= c.near and not cav then cav = b end
    if b.brook == 1 then                         -- BUG-446: 1-3/7 takes no zone and no well: its own branch below
      if b.cavern ~= 1 and b.bank and (not brk or b.d < brk.d) then brk = b end
    elseif b.cavern ~= 1 and b.d <= c.near and (b.bank or (b.dig and not nodig)) then
      if not best or (b.bank and not best.bank) or ((b.bank ~= nil) == (best.bank ~= nil) and b.d < best.d) then
        best = b
      end
    end
    if b.cavern ~= 1 and b.brook ~= 1 and b.d <= c.near and b.pit and (not pit or b.d < pit.d) then pit = b end
  end
  if best and best.bank then
    return string.format('zone the water at %d,%d,%d (%d/7) as Water Source, bank %d,%d,%d is reachable, or a well '
                         .. 'over it%s', best.at[1], best.at[2], best.at[3], best.max, best.bank[1], best.bank[2],
                         best.bank[3], tail)
  elseif pit then                                -- BUG-290: the open hole above the water (a flooded pit) takes a well
    return string.format('build a well at %d,%d,%d over the water at %d,%d,%d (%d/7, open above it, %d,%d,%d reachable)%s',
                         pit.pit[1], pit.pit[2], pit.pit[3], pit.at[1], pit.at[2], pit.at[3], pit.max, pit.stand[1],
                         pit.stand[2], pit.stand[3], tail)
  elseif best then
    local d = best.dig
    return string.format('dig %d wall tile(s) from %d,%d,%d to %d,%d,%d to bare the water at %d,%d,%d, then zone '
                         .. 'it%s', d.n, d.from[1], d.from[2], d.from[3], d.to[1], d.to[2], d.to[3], best.at[1],
                         best.at[2], best.at[3], tail)
  end
  if cis then return cis.fix .. tail end
  local bway = M.best_way(ws)
  if brk and not (bway and bway.kind ~= 'brook' and bway.kind ~= 'dig' and bway.b.d < brk.d) then   -- BUG-446: drink at a brook bank; a cistern brings it
    return string.format('the brook at %d,%d,%d (%d/7 shallow, %d tiles, %d tiles off) is drinkable from the bank %d,%d,%d but takes no Water '
                         .. 'Source zone or well (they want %d/7): a cistern piped to it (python -m dfpilot.bp.sites cistern --near '
                         .. '%d,%d,%d)%s%s', brk.at[1], brk.at[2], brk.at[3], brk.max, brk.n, brk.nd or brk.d, brk.bank[1], brk.bank[2],
                         brk.bank[3], c.deep, brk.at[1], brk.at[2], brk.at[3], aq and (', or ' .. aq) or '', tail)
  end
  local way = bway                             -- BUG-289: water farther than `near` that the citizens reach (a brook)
  if way and way.kind ~= 'dig' and way.kind ~= 'brook' then
    local b = way.b
    local at = way.kind == 'bank' and b.bank or b.pit
    return string.format('the water at %d,%d,%d (%d/7) is %d tiles off (> %d): %s at %d,%d,%d, then the hospital within '
                         .. '%d tiles of it (bp sites hospital)%s', b.at[1], b.at[2], b.at[3], b.max, b.d, c.near,
                         way.kind == 'bank' and 'zone it as Water Source from the bank' or 'a well', at[1], at[2], at[3],
                         c.near, tail)
  end
  local far                                    -- BUG-265: the nearest body without a bank or a dig
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern ~= 1 and b.d <= c.near and (not far or b.d < far.d) then far = b end
  end
  if far then
    local nob = (nodig and far.dig) and 'has no reachable bank'
                or string.format('has no bank and no dig within %d walls', c.ws_dig)
    return string.format('the water at %d,%d,%d (%d/7, %d tiles) %s: a cistern piped to it (python -m dfpilot.bp.sites '
                         .. 'cistern --near %d,%d,%d)%s%s', far.at[1], far.at[2], far.at[3], far.max, far.d, nob,
                         far.at[1], far.at[2], far.at[3], aq and (', or ' .. aq) or '', tail)
  end
  local ctxt = cav and string.format(' (the cavern water at %d,%d,%d is none: caverns stay sealed)', cav.at[1], cav.at[2],
                                     cav.at[3]) or ''
  return string.format('no reachable water >= %d/7 within %d tiles%s: %s%s', c.deep, c.near, ctxt,
                       aq or 'a cistern (bp sites cistern)', tail)
end

-- BUG-031 (Run 11: a cistern stood since y426 and HOSPITAL_DRY said "no reachable water >= 4/7 within 30 tiles: a
-- cistern" every month): why the nearest cistern room of the manifest (tpl cistern; its bbox is the well room, the
-- 3x3 cistern lies one level below) does not serve hospital zone `h`. Its well is the WELL source inside the room; the
-- cistern's water is read on its revealed tiles (snapshot.tile; hidden ones never). Returns nil without a cistern room,
-- else {id, txt (the state: ' cistern <id>: its well <w> at x,y,z stands over 0/7 (dry)', ' ... is 38 tiles from the
-- hospital (> 30)', ' ... has no built well'), fix (what to do), near (within `near` tiles), d}
local function cistern_state(K, c, r, h)
  local best
  for _, rm in ipairs(K.manifest().rooms or {}) do
    local b = rm.tpl == 'cistern' and type(rm.bbox) == 'table' and rm.bbox
    if b and math.tointeger(b[1]) and math.tointeger(b[6]) then
      local well
      for _, s in ipairs(r.sources) do
        if s.kind == 'well' and s.z == b[3] and s.x >= b[1] and s.x <= b[4] and s.y >= b[2] and s.y <= b[5] then
          well = s
        end
      end
      local cx, cy = (b[1] + b[4]) // 2, (b[2] + b[5]) // 2
      local d = dist_box(well and well.x or cx, well and well.y or cy, b[3], h)
      if not best or d < best.d then best = {rm = rm, well = well, d = d, at = {cx, cy, b[3]}, b = b} end
    end
  end
  if not best then return nil end
  local id, w, at = tostring(best.rm.id or '?'), best.well, best.at
  local maxf, seen = 0, 0                     -- the deepest revealed water of the cistern below the room
  for y = best.b[2], best.b[5] do
    for x = best.b[1], best.b[4] do
      local t = tile(K, x, y, best.b[3] - 1)
      if t then
        seen = seen + 1
        local f = math.tointeger(t.flow) or (t.c == '~' and 4 or (t.c == 'w' and 1 or 0))
        if f > maxf then maxf = f end
      end
    end
  end
  local out = {id = id, d = best.d, near = best.d <= c.near}
  local far = not out.near and string.format(', %d tiles from the hospital (> %d)', best.d, c.near) or ''
  if not w then
    out.txt = string.format('cistern %s at %d,%d,%d has no well%s', id, at[1], at[2], at[3], far)
    out.fix = out.txt .. ': build it'
  elseif not w.built then
    out.txt = string.format('cistern %s: its well %d at %d,%d,%d is not built%s', id, w.id, w.x, w.y, w.z, far)
    out.fix = out.txt .. ': finish it'
  elseif w.loop then                          -- BUG-263: water from its own pond only
    out.txt = string.format('cistern %s: its well %d at %d,%d,%d is fed only by its own pond %d (a loop)%s', id, w.id, w.x,
                            w.y, w.z, w.loop, far)
    out.fix = out.txt .. ': a source outside (a Water Source zone on a brook, its pipe, or water=aquifer)'
  elseif not w.wet then
    local bl = w.below or {}
    local p = bl.at or {w.x, w.y, w.z - 1}
    local what = bl.why == 'hidden' and 'a hidden tile' or (bl.why == 'rock' and 'rock'
                 or (bl.why == 'deep' and 'a dry shaft'
                 or (bl.why == 'shallow' and string.format('%d/7 (shallow, < %d/7)', bl.flow or 0, c.well_min or 3)
                 or string.format('%d/7 (dry)', bl.flow or 0))))
    out.txt = string.format('cistern %s: its well %d stands over %s at %d,%d,%d (cistern max %d/7)%s', id, w.id, what,
                            p[1], p[2], p[3], maxf, far)
    out.fix = out.txt .. ': fill it (pond zone and bucket carriers, or its pipe)'
  else
    out.txt = string.format('cistern %s: its well %d at %d,%d,%d (water %d/7) is %d tiles from the hospital (> %d)', id,
                            w.id, w.x, w.y, w.z, (w.below and w.below.flow) or maxf, best.d, c.near)
    out.fix = out.txt .. ': a hospital zone near it'
  end
  out.max, out.seen = maxf, seen
  return out
end

-- BUG-288/289: the scan's plan is box arithmetic (module fields: tested on their own). M.box_n: tiles of a box
-- {x1, y1, z1, x2, y2, z2}; M.merge_boxes: boxes whose union costs no more than both apart become that union (the
-- earlier box keeps its place: the order is the reading priority)
function M.first(t, n)
  local o = {}
  for i = 1, math.min(n, #t) do o[i] = t[i] end
  return o
end
function M.box_n(b) return (b[4] - b[1] + 1) * (b[5] - b[2] + 1) * (b[6] - b[3] + 1) end
function M.merge_boxes(list)
  local out = {}
  for _, b in ipairs(list) do out[#out + 1] = {b[1], b[2], b[3], b[4], b[5], b[6]} end
  local i = 1
  while i <= #out do
    local merged = false
    for j = 1, #out do
      local a, b = out[i], out[j]
      if j ~= i then
        local u = {math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]), math.max(a[4], b[4]),
                   math.max(a[5], b[5]), math.max(a[6], b[6])}
        if M.box_n(u) <= M.box_n(a) + M.box_n(b) then
          local k = math.min(i, j)
          out[k] = u
          table.remove(out, math.max(i, j))
          merged, i = true, 1
          break
        end
      end
    end
    if not merged then i = i + 1 end
  end
  return out
end
local function clamp_box(b, X, Y, Z)
  local r = {math.max(0, b[1]), math.max(0, b[2]), math.max(0, b[3]), b[4], b[5], b[6]}
  if X then r[4], r[5], r[6] = math.min(X - 1, r[4]), math.min(Y - 1, r[5]), math.min((Z or r[6] + 1) - 1, r[6]) end
  if r[1] > r[4] or r[2] > r[5] or r[3] > r[6] then return nil end
  return r
end
local function in_box(b, x, y, z) return x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] end

-- BUG-325 (Run 15 Earthboat: two scans of the same 1490 tiles in 12 bodies said '12 with a well spot' and '0 with a well
-- spot' a few days apart): the scan asked snapshot.reach from ONE citizen, the one nearest the reference; when he stood in
-- another walk group (the sealed refuge, a stranded woodcutter, a dwarf on a tree) every bank and well spot read
-- unreachable. Now up to `n` origins, the citizens nearest the reference on distinct tiles; a tile counts as reachable when
-- any of them reaches it (M.reach_any: true / false, nil = unknown: no origin)
function M.origins(home, ref, n)
  local l, seen = {}, {}
  for _, h in ipairs(home or {}) do
    local k = k3(h.x, h.y, h.z)
    if not seen[k] then
      seen[k] = true
      l[#l + 1] = {h = h, d = dist_box(h.x, h.y, h.z, ref)}
    end
  end
  table.sort(l, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return k3(a.h.x, a.h.y, a.h.z) < k3(b.h.x, b.h.y, b.h.z)
  end)
  local out = {}
  for i = 1, math.min(math.max(1, n or 1), #l) do out[i] = {x = l[i].h.x, y = l[i].h.y, z = l[i].h.z} end
  return out
end

function M.reach_any(K, froms, to)
  if #(froms or {}) == 0 then return nil end
  for _, f in ipairs(froms) do
    local ok, yes = K.call('snapshot', 'reach', f, to)
    if not ok or yes ~= false then return true end
  end
  return false
end

-- the scan of the hospital's surroundings (else the citizens'); BUG-289: plus every citizen's, the bodies the last scans
-- found (p.wb), the map's surface levels (survey) and what the survey meets; BUG-288: within ws_read_max tiles, the
-- hospital's or the median's box first
local function new_scan(K, c, r, p)
  local core, ref = {}, nil
  for i = 1, math.min(2, #r.hosp) do
    local h = r.hosp[i]
    core[#core + 1] = {h.x1 - c.near, h.y1 - c.near, h.z - c.ws_dz, h.x2 + c.near, h.y2 + c.near, h.z + c.ws_dz}
  end
  if r.hosp[1] then
    local h = r.hosp[1]
    ref = {x1 = h.x1, y1 = h.y1, x2 = h.x2, y2 = h.y2, z = h.z}
  elseif #r.home > 0 then
    local mx, my, mz = median(r.home, 'x'), median(r.home, 'y'), median(r.home, 'z')
    core[1] = {mx - c.near, my - c.near, mz - c.ws_dz, mx + c.near, my + c.near, mz + c.ws_dz}
    ref = {x1 = mx, y1 = my, x2 = mx, y2 = my, z = mz}
  else
    return nil
  end
  local okm, X, Y, Z = K.call('snapshot', 'map_size')
  if not (okm and math.tointeger(X) and math.tointeger(Y)) then X, Y, Z = nil, nil, nil end
  local wide = {}
  for _, b in ipairs(type(p.wb) == 'table' and p.wb or {}) do               -- the bodies the last scans found
    local x, y, z = math.tointeger(b[1]), math.tointeger(b[2]), math.tointeger(b[3])
    if x and y and z then
      wide[#wide + 1] = {x - c.ws_mem_r, y - c.ws_mem_r, z - 1, x + c.ws_mem_r, y + c.ws_mem_r, z + 1}
    end
  end
  for _, h in ipairs(r.home) do                                             -- every citizen (a drinker at the brook)
    wide[#wide + 1] = {h.x - c.ws_cit, h.y - c.ws_cit, h.z - 1, h.x + c.ws_cit, h.y + c.ws_cit, h.z + 1}
  end
  local survey, scost = {}, 0
  if X and c.ws_survey_levels > 0 and c.ws_lattice >= 2 then
    local seen = {}
    local per = (X * Y + c.ws_lattice - 1) // c.ws_lattice
    for _, at in ipairs({{ref.x1, ref.y1}, {X // 2, Y // 2}}) do
      local ok, sz = K.call('snapshot', 'surface_z', at[1], at[2])
      sz = ok and math.tointeger(sz) or nil
      for dz = 0, sz and c.ws_survey_levels - 1 or -1 do
        local z = sz - dz
        if z >= 0 and not seen[z] and scost + per <= c.ws_survey_max then
          seen[z], survey[#survey + 1], scost = true, z, scost + per
        end
      end
    end
  end
  local left = c.ws_read_max - scost - (#survey > 0 and c.ws_seed_max or 0)
  local boxes, cut = {}, 0
  for _, b in ipairs(M.merge_boxes(core)) do                                -- always read
    local cb = clamp_box(b, X, Y, Z)
    if cb then boxes[#boxes + 1], left = cb, left - M.box_n(cb) end
  end
  local ncore = #boxes
  for _, b in ipairs(M.merge_boxes(wide)) do
    local cb, inside = clamp_box(b, X, Y, Z), false
    for i = 1, ncore do
      local o = boxes[i]
      if cb and in_box(o, cb[1], cb[2], cb[3]) and in_box(o, cb[4], cb[5], cb[6]) then inside = true end
    end
    if cb and not inside then
      if M.box_n(cb) <= left then boxes[#boxes + 1], left = cb, left - M.box_n(cb) else cut = cut + 1 end
    end
  end
  local froms = M.origins(r.home, ref, c.ws_from)   -- BUG-325: walk origins, the citizens nearest the reference
  return {boxes = boxes, bi = 1, tiles = {}, n = 0, ref = ref, from = froms[1], froms = froms,
          stage = #survey > 0 and 'survey' or 'read',
          sources = r.sources, bk = 0, out = {}, survey = survey, si = 1, X = X, Y = Y, Z = Z, cut = cut,
          seed_left = #survey > 0 and c.ws_seed_max or 0, seeds = 0, hits = {}, aqz = {}, reads = 0, slices = 0,
          quota = math.max(c.ws_tiles, (c.ws_read_max + c.ws_slices - 1) // c.ws_slices)}
end

-- BUG-289: one slice of the survey: rows of a surface level of the whole map, every ws_lattice-th tile (snapshot.liquids
-- lattice); deep water outside caverns is kept as a seed. A failure ends the survey only (the boxes are read anyway)
local function scan_survey(K, c, sc)
  local budget, lat = sc.quota, c.ws_lattice
  while budget > 0 do
    local z = sc.survey[sc.si]
    if not z then return true end
    sc.y = sc.y or 0
    local rows = math.max(1, math.min(sc.Y - sc.y, (budget * lat) // sc.X, (4096 * lat) // sc.X))
    local ok, list, err = K.call('snapshot', 'liquids', 0, sc.y, sc.X - 1, sc.y + rows - 1, z, c.deep, false, lat,
                            c.brook_min > 0 and c.brook_min or nil)
    if not ok or type(list) ~= 'table' then
      sc.serr = 'survey: ' .. tostring(ok and err or list)
      return true
    end
    for _, t in ipairs(list) do
      if t[4] ~= 1 and #sc.hits < 2000 then sc.hits[#sc.hits + 1] = {t[1], t[2], z} end
    end
    local cost = (sc.X * rows + lat - 1) // lat
    budget, sc.reads = budget - cost, sc.reads + cost
    sc.y = sc.y + rows
    if sc.y >= sc.Y then sc.si, sc.y = sc.si + 1, nil end
  end
  return false
end

-- BUG-289: a ws_seed_r box round each survey hit no box reads yet, within ws_seed_max tiles
local function scan_seed(c, sc)
  local seeds = {}
  for _, h in ipairs(sc.hits) do
    local inside = false
    for _, b in ipairs(sc.boxes) do if in_box(b, h[1], h[2], h[3]) then inside = true end end
    for _, b in ipairs(seeds) do if in_box(b, h[1], h[2], h[3]) then inside = true end end
    if not inside then
      seeds[#seeds + 1] = {h[1] - c.ws_seed_r, h[2] - c.ws_seed_r, h[3], h[1] + c.ws_seed_r, h[2] + c.ws_seed_r, h[3]}
    end
  end
  for _, b in ipairs(M.merge_boxes(seeds)) do
    local cb = clamp_box(b, sc.X, sc.Y, sc.Z)
    if cb and M.box_n(cb) <= sc.seed_left then
      sc.boxes[#sc.boxes + 1], sc.seed_left, sc.seeds = cb, sc.seed_left - M.box_n(cb), sc.seeds + 1
    elseif cb then
      sc.cut = sc.cut + 1
    end
  end
  sc.hits = nil
end

-- one slice of reading: rows of the current level of the current box through snapshot.liquids (BUG-288: sc.quota tiles)
local function scan_read(K, c, sc)
  local budget = sc.quota
  while budget > 0 do
    local b = sc.boxes[sc.bi]
    if not b then return true end
    sc.z, sc.y = sc.z or b[3], sc.y or b[2]
    if sc.z > b[6] then
      sc.bi, sc.z, sc.y = sc.bi + 1, nil, nil
    else
      local w = b[4] - b[1] + 1
      local rows = math.max(1, math.min(b[5] - sc.y + 1, budget // w, 4096 // w))
      local ok, list, err = K.call('snapshot', 'liquids', b[1], sc.y, b[4], sc.y + rows - 1, sc.z, c.deep, false, nil,
                            c.brook_min > 0 and c.brook_min or nil)
      if not ok or type(list) ~= 'table' then
        sc.err = 'snapshot.liquids: ' .. tostring(ok and err or list)
        return true
      end
      for _, t in ipairs(list) do
        local key = k3(t[1], t[2], sc.z)
        if not sc.tiles[key] and sc.n < 6000 then sc.tiles[key], sc.n = {t[1], t[2], sc.z, t[3], t[4], t[6]}, sc.n + 1 end
      end
      budget, sc.reads = budget - w * rows, sc.reads + w * rows
      sc.y = sc.y + rows
      if sc.y > b[5] then sc.y, sc.z = b[2], sc.z + 1 end
    end
  end
  return false
end

-- deep tiles -> bodies (8-connected on one level), nearest to the reference first, at most ws_bodies (BUG-289: the three
-- largest of the rest among them: a brook farther off than a few pools)
local function scan_group(c, sc)
  local keys, seen, bodies = {}, {}, {}
  for k in pairs(sc.tiles) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if not seen[k] then
      seen[k] = true
      local t0 = sc.tiles[k]
      local body, stack = {z = t0[3], tiles = {}, max = 0, d = math.huge, cav = 0}, {t0}
      while #stack > 0 do
        local t = table.remove(stack)
        body.tiles[#body.tiles + 1] = t
        if t[4] > body.max then body.max = t[4] end
        if t[5] == 1 then body.cav = 1 end            -- BUG-031: a cavern tile makes it cavern water
        local d = dist_box(t[1], t[2], t[3], sc.ref)
        if d < body.d then body.d = d end
        for _, o in ipairs(N8) do
          local nk = k3(t[1] + o[1], t[2] + o[2], t[3])
          if sc.tiles[nk] and not seen[nk] then seen[nk] = true; stack[#stack + 1] = sc.tiles[nk] end
        end
      end
      -- BUG-423 (Run 16a i1 Manorsubtle: one body of 1229 tiles, `at` 10,0,158 = its first tile in y order at the map edge, 80 tiles
      -- from the brook in the gully beside the start room; 'bp sites cistern --near 10,0,158' found no site, and the bank search
      -- spent its 400 reads at the far end): the tiles run nearest first (to the reference box or to a citizen's walk origin,
      -- then y, x) so `at` is the water tile NEAREST to the fort and the bank / dig / well-spot search starts there
      local function near_d(t)             -- Chebyshev distance (the scan's measure) and, to break the many ties, the squared one
        local rx = t[1] < sc.ref.x1 and sc.ref.x1 - t[1] or (t[1] > sc.ref.x2 and t[1] - sc.ref.x2 or 0)
        local ry = t[2] < sc.ref.y1 and sc.ref.y1 - t[2] or (t[2] > sc.ref.y2 and t[2] - sc.ref.y2 or 0)
        local rz = math.abs(t[3] - sc.ref.z)
        local d, d2 = math.max(rx, ry, rz), rx * rx + ry * ry + rz * rz
        for _, f in ipairs(sc.froms or {}) do
          local fx, fy, fz = math.abs(t[1] - f.x), math.abs(t[2] - f.y), math.abs(t[3] - f.z)
          local df = math.max(fx, fy, fz)
          if df < d or (df == d and fx * fx + fy * fy + fz * fz < d2) then d, d2 = df, fx * fx + fy * fy + fz * fz end
        end
        return d, d2
      end
      for _, t in ipairs(body.tiles) do t.nd, t.n2 = near_d(t) end
      table.sort(body.tiles, function(a, b)
        if a.nd ~= b.nd then return a.nd < b.nd end
        if a.n2 ~= b.n2 then return a.n2 < b.n2 end
        return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1])
      end)
      body.at = {body.tiles[1][1], body.tiles[1][2], body.z}
      body.nd = body.tiles[1].nd
      body.brook = body.max < c.deep and 1 or nil      -- BUG-446: only shallow brook tiles (the deeper ones are water as ever)
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, t in ipairs(body.tiles) do
        if t[1] < x0 then x0 = t[1] end
        if t[1] > x1 then x1 = t[1] end
        if t[2] < y0 then y0 = t[2] end
        if t[2] > y1 then y1 = t[2] end
      end
      body.ext = {x0, y0, x1, y1}
      bodies[#bodies + 1] = body
    end
  end
  local function near_first(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if #a.tiles ~= #b.tiles then return #a.tiles > #b.tiles end
    if a.z ~= b.z then return a.z > b.z end
    return a.at[2] < b.at[2] or (a.at[2] == b.at[2] and a.at[1] < b.at[1])
  end
  table.sort(bodies, near_first)
  if #bodies > c.ws_bodies then
    local keep, rest = {}, {}
    local nk = math.max(0, c.ws_bodies - 3)
    for i, b in ipairs(bodies) do if i <= nk then keep[#keep + 1] = b else rest[#rest + 1] = b end end
    table.sort(rest, function(a, b)
      if #a.tiles ~= #b.tiles then return #a.tiles > #b.tiles end
      return near_first(a, b)
    end)
    for i = 1, c.ws_bodies - nk do keep[#keep + 1] = rest[i] end
    table.sort(keep, near_first)
    bodies = keep
  end
  sc.list = bodies
end

-- one body: the accepted zone or well over it, a reachable bank, else the shortest dig to one. BUG-290: open space right
-- above a body tile beside a floor the citizens reach on that level is a well spot (`pit`: build the well there).
-- BUG-291: a revealed tile with the aquifer flag in or beside the body marks its level (sc.aqz)
local function scan_body(K, c, sc, body)
  local z, deepset = body.z, sc.tiles
  local res = {z = z, n = #body.tiles, max = body.max, at = body.at, d = body.d, nd = body.nd, ext = body.ext, zone = -1, well = -1, reach = 0,
               brook = body.brook}
  -- BUG-031 (Run 11: a 7/7 cavern lake 1146 tiles on z127 below an aborted shaft): caverns stay sealed (DOCTRINE: every
  -- breach of caverns through a 2-wall airlock), so cavern water is listed but never looked at for a bank or a dig
  if body.cav == 1 then res.cavern = 1; return res end
  for _, s in ipairs(sc.sources or {}) do
    for _, t in ipairs(body.tiles) do
      if s.kind == 'zone' and s.wet and s.box and (s.box.z == z or (c.zone_below == true and s.box.z == z + 1))
         and t[1] >= s.box.x1 and t[1] <= s.box.x2 and t[2] >= s.box.y1 and t[2] <= s.box.y2 then res.zone = s.id end
      if s.kind == 'well' and s.wet and s.z > z and s.x == t[1] and s.y == t[2] then res.well = s.id end
    end
  end
  local checks = 0
  local function reachable(x, y, zz)
    local froms = sc.froms or (sc.from and {sc.from}) or {}
    if #froms == 0 then return true end
    if checks >= c.ws_reach then return nil end
    checks = checks + 1
    return M.reach_any(K, froms, {x = x, y = y, z = zz or z})
  end
  if c.pit_well and res.well == -1 and res.zone == -1 and not res.brook then     -- BUG-446: a well over 1-3/7 gives no water
    for i = 1, math.min(16, #body.tiles) do
      local t = body.tiles[i]
      local own = tile(K, t[1], t[2], z)
      if own and own.aq == true then sc.aqz[z] = sc.aqz[z] or {t[1], t[2], z} end
      local up = not res.pit and tile(K, t[1], t[2], z + 1)
      if up and (up.c == '_' or up.c == 'v') then          -- open space; 'v' over a channel's ramp (a pit)
        for _, o in ipairs(N8) do
          local nb = tile(K, t[1] + o[1], t[2] + o[2], z + 1)
          if nb and STAND[nb.c] and not wet_char(nb.c) and not res.pit then
            local yes = reachable(t[1] + o[1], t[2] + o[2], z + 1)
            if yes then res.pit, res.stand = {t[1], t[2], z + 1}, {t[1] + o[1], t[2] + o[2], z + 1} end
          end
        end
      end
    end
  end
  -- at most ws_reads tile reads per body (one body a frame): a big lake must not make the module slow
  local reads = 0
  local function read(x, y)
    if reads >= c.ws_reads then res.partial = 1; return nil end
    reads = reads + 1
    local t = tile(K, x, y, z)
    if t and t.aq == true then sc.aqz[z] = sc.aqz[z] or {x, y, z} end
    return t
  end
  local seen, walls = {}, {}
  for _, t in ipairs(body.tiles) do
    if reads >= c.ws_reads then res.partial = 1; break end
    for _, o in ipairs(N8) do
      local x, y = t[1] + o[1], t[2] + o[2]
      local key = k3(x, y, z)
      if not deepset[key] and not seen[key] then
        seen[key] = true
        local tt = read(x, y)
        if tt and STAND[tt.c] and not M.deep_tile(tt, c) then
          local yes = reachable(x, y)
          if yes then res.bank, res.reach, res.wt = {x, y, z}, 1, {t[1], t[2], z}; return res end   -- wt: its water tile
          if yes == nil then return res end
        elseif tt and DIGGABLE[tt.c] then
          walls[#walls + 1] = {x, y, key, x, y}
        end
      end
    end
  end
  -- no reachable bank: breadth first through revealed natural wall (each wall dug counts one), up to ws_dig
  local qi, depth = 1, {}
  for _, w in ipairs(walls) do depth[w[3]] = 1 end
  while qi <= #walls do
    local w = walls[qi]
    qi = qi + 1
    local dw = depth[w[3]]
    for _, o in ipairs(N8) do
      local x, y = w[1] + o[1], w[2] + o[2]
      local key = k3(x, y, z)
      if not deepset[key] and not seen[key] then
        seen[key] = true
        local tt = read(x, y)
        if tt and STAND[tt.c] and not M.deep_tile(tt, c) then
          local yes = reachable(x, y)
          if yes then
            res.dig = {n = dw, from = {x, y, z}, to = {w[4], w[5], z}}
            return res
          end
          if yes == nil then return res end
        elseif tt and DIGGABLE[tt.c] and dw < c.ws_dig then
          depth[key] = dw + 1
          walls[#walls + 1] = {x, y, key, w[4], w[5]}
        end
      end
    end
  end
  return res
end

-- BUG-289/290: the best way to water the last scan offers (any distance): {kind = 'bank' | 'well' | 'dig', b = body}, the
-- nearest bank first, then a well spot, then the shortest dig; nil without one
function M.best_way(ws)
  local best = {}
  for _, b in ipairs(ws and ws.bodies or {}) do
    if b.cavern ~= 1 then
      -- BUG-446: a shallow brook is no zone or well water: its bank is a place to drink ('brook'), offered after the rest
      for _, k in ipairs({{b.brook == 1 and 'brook' or 'bank', b.bank}, {'well', b.pit}, {'dig', b.dig}}) do
        if k[2] and (not best[k[1]] or b.d < best[k[1]].d) then best[k[1]] = b end
      end
    end
  end
  for _, k in ipairs({'bank', 'well', 'dig', 'brook'}) do if best[k] then return {kind = k, b = best[k]} end end
end

-- the short text of M.best_way (state water.wsc, <= 96 bytes; bp sites hospital names it when no accepted water exists)
function M.way_text(w)
  if not w then return nil end
  local b = w.b
  if w.kind == 'brook' then      -- BUG-446
    return trunc(string.format('brook %d,%d,%d (%d/7, %d tiles) drinkable from bank %d,%d,%d; no zone below 4/7: piped cistern',
                               b.at[1], b.at[2], b.at[3], b.max, b.n, b.bank[1], b.bank[2], b.bank[3]), 96)
  elseif w.kind == 'bank' then
    return trunc(string.format('water %d,%d,%d (%d/7, %d tiles): bank %d,%d,%d reachable: zone it or a well over it',
                               b.at[1], b.at[2], b.at[3], b.max, b.n, b.bank[1], b.bank[2], b.bank[3]), 96)
  elseif w.kind == 'well' then
    return trunc(string.format('water %d,%d,%d (%d/7): a well at %d,%d,%d over it (open above, reachable)', b.at[1],
                               b.at[2], b.at[3], b.max, b.pit[1], b.pit[2], b.pit[3]), 96)
  end
  return trunc(string.format('water %d,%d,%d (%d/7): dig %d wall(s) from %d,%d,%d', b.at[1], b.at[2], b.at[3], b.max,
                             b.dig.n, b.dig.from[1], b.dig.from[2], b.dig.from[3]), 96)
end

---------------------------------------------------------------- BUG-324: found water becomes accepted water
-- Run 15 Inkintense (y376-377: the scan found 7/7 water at 88,102,132 under an open tile with a reachable floor beside it,
-- 'hospital still needs accepted water', no hospital for 4 years) and Earthboat (y384-385: the river's 7/7 water under its
-- ramp tops, a dry well 17700, '1 GiveWater job open, none taken by 53 idle', patients at thirst 37,348): the scan only
-- wrote a recipe; nothing ever zoned the water, so water.src stayed empty, bp sites hospital refused every site and the
-- game had no water source for GiveWater. Now, while no water is accepted, the kernel paints a 1x1 Water Source zone
-- dfllm-water (act.water_zone, the zones screen) on the scan's best water: a body with a reachable bank on its own level
-- (the water tile beside it), else a well spot (the water under the open tile, the zone on both levels: the carrier's
-- floor is one level up, as for fishing, BUG-296). Safe only: never cavern water, never a bank on the attack path
-- (manifest Z1/Z2, killboxes), never in BREACH; outside PEACE/RECOVERY only a bank known to be roofed (snapshot
-- outside_near); a roofed bank first, then the nearest. The next water run reads the zone over deep water as accepted
-- (zone_wet), water.src carries it, bp sites hospital ranks by it. At most one zone every wz_every, wz_max spots within
-- wz_forget, a spot tried (or already inside a zone) not again.
function M.on_attack_path(K, q)
  local ok, man = pcall(K.manifest)
  man = ok and type(man) == 'table' and man or {}
  local function inb(b)
    return type(b) == 'table' and #b >= 6 and q[1] >= b[1] and q[1] <= b[4] and q[2] >= b[2] and q[2] <= b[5]
           and q[3] >= b[3] and q[3] <= b[6]
  end
  for _, k in ipairs({'Z1', 'Z2'}) do
    for _, b in ipairs(type(man.zones) == 'table' and type(man.zones[k]) == 'table' and man.zones[k] or {}) do
      if inb(b) then return true end
    end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if type(kb) == 'table' and inb(kb.bbox) then return true end
  end
  return false
end

-- the candidates of the last scan: {wt = the water tile, up = the carrier's floor one level higher, stand, b}, nearest first
function M.zone_cands(ws)
  local out = {}
  for _, b in ipairs(ws and ws.bodies or {}) do
    if b.cavern ~= 1 and b.zone == -1 and b.well == -1 and b.brook ~= 1 then     -- BUG-446: the game takes no zone on 1-3/7
      if b.bank and b.wt then out[#out + 1] = {wt = b.wt, stand = b.bank, up = false, b = b} end
      if b.pit and b.stand then
        out[#out + 1] = {wt = {b.pit[1], b.pit[2], b.pit[3] - 1}, stand = b.stand, up = true, b = b}
      end
    end
  end
  table.sort(out, function(a, b)
    if a.b.d ~= b.b.d then return a.b.d < b.b.d end
    if a.up ~= b.up then return not a.up end
    return k3(a.wt[1], a.wt[2], a.wt[3]) < k3(b.wt[1], b.wt[2], b.wt[3])
  end)
  return out
end

-- one run: nil, or {at, up, ok, txt} when a zone was painted (or refused) now
function M.zone_found(K, c, r, p, now)
  if c.wz == false or not M.can('water_zone') or not st.ws then return nil end
  local mode = K.mode()
  if mode == 'BREACH' then return nil end
  p.wzt = json.array(type(p.wzt) == 'table' and p.wzt or {})
  local keep = json.array{}
  for _, e in ipairs(p.wzt) do                          -- {key, tick}: the spots tried, forgotten after wz_forget
    if type(e) == 'table' and math.tointeger(e[2]) and now - e[2] < c.wz_forget then keep[#keep + 1] = e end
  end
  p.wzt = keep
  if #keep >= c.wz_max or now - (math.tointeger(p.wz_t) or -c.wz_every) < c.wz_every then return nil end
  local tried = {}
  for _, e in ipairs(keep) do tried[e[1]] = true end
  local function zoned(t)                               -- already inside a Water Source zone (one that reads dry)
    for _, s in ipairs(r.sources) do
      local bx = s.kind == 'zone' and s.box
      if bx and bx.z == t[3] and t[1] >= bx.x1 and t[1] <= bx.x2 and t[2] >= bx.y1 and t[2] <= bx.y2 then return true end
    end
    return false
  end
  local free = mode == 'PEACE' or mode == 'RECOVERY'
  local best
  for _, cd in ipairs(M.zone_cands(st.ws)) do
    local key = k3(cd.wt[1], cd.wt[2], cd.wt[3])
    if not tried[key] and not zoned(cd.wt) and not M.on_attack_path(K, cd.stand) and not M.on_attack_path(K, cd.wt) then
      local oko, sky = K.call('snapshot', 'outside_near', {cd.stand}, 0)
      cd.inside = oko and type(sky) == 'table' and sky[1] == 0
      if cd.inside then best = cd; break end
      if free and not best then best = cd end
    end
  end
  if not best then return nil end
  local w, s = best.wt, best.stand
  local key = k3(w[1], w[2], w[3])
  p.wzt[#p.wzt + 1] = json.array{key, now}
  p.wz_t = now
  local ok, n = K.act.water_zone({w[1], w[2], w[3]}, best.up)
  local where = string.format('%d,%d,%d (%d/7%s; carrier floor %d,%d,%d%s)', w[1], w[2], w[3], best.b.max,
                              best.up and ', open above' or '', s[1], s[2], s[3], best.inside and ', roofed' or '')
  local out = {at = w, up = best.up, ok = ok and 1 or 0}
  if ok then
    out.txt = 'Water Source zone dfllm-water painted at ' .. where .. ': accepted after the next water run'
    K.log('info', 'water: %s (no accepted water; %s)', out.txt, mode)
  else
    out.txt = trunc(string.format('Water Source zone at %d,%d,%d refused: %s', w[1], w[2], w[3], tostring(n)), 100)
    K.log('warn', 'water: %s', out.txt)
  end
  p.wz = {at = json.array{w[1], w[2], w[3]}, up = best.up and 1 or 0, t = now, ok = out.ok}
  return out
end

local function scan_done(K, c, sc, p)
  local levels, byz = {}, {}
  for _, t in pairs(sc.tiles) do byz[t[3]] = (byz[t[3]] or 0) + 1 end
  for z, n in pairs(byz) do levels[#levels + 1] = {z, n} end
  table.sort(levels, function(a, b) return a[1] > b[1] end)
  local now = K.now().tick
  -- BUG-291: the levels where a revealed aquifer tile touches the water (the manifest's aquifer_levels through the runner)
  p.aqz = type(p.aqz) == 'table' and p.aqz or json.array{}
  local aql = {}
  for z, at in pairs(sc.aqz) do
    local known = false
    for _, v in ipairs(p.aqz) do if v == z then known = true end end
    if not known and #p.aqz < 16 then
      p.aqz[#p.aqz + 1] = z
      K.log('info', 'water sources: aquifer level z%d (a revealed aquifer tile at %d,%d,%d beside water >= %d/7)', z, at[1],
            at[2], at[3], c.deep)
    end
    K.call('runner', 'aq_seen', z)
    aql[#aql + 1] = z
  end
  table.sort(aql)
  st.ws = {tick = now, deep = c.deep, boxes = sc.boxes, tiles = sc.n, levels = levels, bodies = sc.out,
           err = sc.err, serr = sc.serr, slices = sc.slices, reads = sc.reads, survey = sc.survey, seeds = sc.seeds,
           cut = sc.cut, aq = aql}
  -- BUG-289: the bodies to look at again next time (banks and well spots first, then the largest)
  local mem = {}
  for _, b in ipairs(sc.out) do if b.cavern ~= 1 then mem[#mem + 1] = b end end
  table.sort(mem, function(a, b)
    local ra, rb = (a.bank or a.pit) and 1 or 0, (b.bank or b.pit) and 1 or 0
    if ra ~= rb then return ra > rb end
    if a.n ~= b.n then return a.n > b.n end
    return a.d < b.d
  end)
  p.wb = json.array{}
  for i = 1, math.min(c.ws_mem, #mem) do p.wb[i] = json.array{mem[i].at[1], mem[i].at[2], mem[i].at[3]} end
  p.ws_last = {t = now, slices = sc.slices, reads = sc.reads, bodies = #sc.out, boxes = #sc.boxes}
  K.persist.touch('m.water')
  local reach, pits = 0, 0
  for _, b in ipairs(sc.out) do
    if b.bank or b.dig then reach = reach + 1 end
    if b.pit then pits = pits + 1 end
  end
  K.log('info', 'water sources: %d tiles >= %d/7 in %d bodies, %d with a bank or a dig, %d with a well spot (%d slices, %d '
        .. 'tiles read, %d boxes)%s', sc.n, c.deep, #sc.out, reach, pits, sc.slices, sc.reads, #sc.boxes,
        sc.err and (' (' .. sc.err .. ')') or '')
end

-- one frame of the scan: true while more remains. BUG-288: at most quota tiles a slice, ws_body_slices slices of bodies
local function scan_step(K, c, p)
  local sc = st.scan
  sc.slices = sc.slices + 1
  if sc.stage == 'survey' then
    if not scan_survey(K, c, sc) then return true end
    scan_seed(c, sc)
    sc.stage = 'read'
    return true
  end
  if sc.stage == 'read' then
    if not scan_read(K, c, sc) then return true end
    if sc.err then scan_done(K, c, sc, p); return false end
    scan_group(c, sc)
    sc.stage = 'bodies'
    sc.per = math.max(1, (#sc.list + c.ws_body_slices - 1) // math.max(1, c.ws_body_slices))
    if #sc.list > 0 then return true end
  end
  for _ = 1, sc.per or 1 do
    sc.bk = sc.bk + 1
    local body = sc.list[sc.bk]
    if body then sc.out[#sc.out + 1] = scan_body(K, c, sc, body) end
  end
  if sc.bk < #sc.list then return true end
  scan_done(K, c, sc, p)
  return false
end

---------------------------------------------------------------- hospital zones drawn again (BUG-539)
-- p.hrm: the hospital zones this module removed and has not drawn again: {id, loc, x1, y1, x2, y2, z, t, why 'dry'|'stall'}
-- (at most HRM_MAX, the oldest go first). Persisted: a reload keeps them.
local HRM_MAX = 12
function M.remember(p, h, now, why)
  local list = json.array(type(p.hrm) == 'table' and p.hrm or {})
  for _, e in ipairs(list) do if e.id == h.id then return end end
  list[#list + 1] = {id = h.id, loc = h.loc, x1 = h.x1, y1 = h.y1, x2 = h.x2, y2 = h.y2, z = h.z, t = now, why = why}
  while #list > HRM_MAX do table.remove(list, 1) end
  p.hrm = list
end

-- BUG-540 (Run 16b i2 Brotherarrow: the zone 18030 was removed before BUG-539 remembered anything; the hospital LOCATION and the
-- room with its beds stood on, `bp sites hospital` found no site): the manifest's hospital rooms that no live hospital zone covers
-- are paired with the zoneless hospital locations of the last run (r.orph) -- entries like p.hrm's, why 'room', never stored.
function M.orphan_rooms(K, r)
  local out = {}
  if not r or type(r.orph) ~= 'table' or #r.orph == 0 then return out end
  local used = {}
  local ok, man = pcall(K.manifest)
  for _, rm in ipairs(ok and man and man.rooms or {}) do
    local b = rm.bbox
    if rm.tpl == 'hospital' and type(b) == 'table' and #b >= 6 then
      local covered = false
      for _, h in ipairs(r.hosp) do
        if h.z == b[3] and h.x1 <= b[4] and h.x2 >= b[1] and h.y1 <= b[5] and h.y2 >= b[2] then covered = true end
      end
      if not covered then
        for _, loc in ipairs(r.orph) do
          if not used[loc] then
            used[loc] = true
            out[#out + 1] = {id = 0, loc = loc, x1 = b[1], y1 = b[2], x2 = b[4], y2 = b[5], z = b[3], why = 'room', orph = true}
            break
          end
        end
      end
    end
  end
  return out
end

-- the remembered zones that still count (BUG-540): not expired, and a dry one only while accepted water stands within near of the
-- old room; the zoneless hospital rooms (M.orphan_rooms) while no hospital zone stands, served likewise. This is what bp sites
-- reads (state water.hrm): a dry memory must not block a site that has water
function M.hrm_count(K, c, r, p, now)
  local n = 0
  for _, e in ipairs(type(p.hrm) == 'table' and p.hrm or {}) do
    if now - (math.tointeger(e.t) or now) < c.hrm_expire and (e.why ~= 'dry' or (r ~= nil and (served(K, c, r, e)) == true)) then
      n = n + 1
    end
  end
  if r and #r.hosp == 0 then
    for _, e in ipairs(M.orphan_rooms(K, r)) do if (served(K, c, r, e)) == true then n = n + 1 end end
  end
  return n
end

-- Draws the remembered zones again (act.hospital_restore: the same location, the same rectangle). opt.force: all of them (or
-- those of opt.loc) now, whatever the rules; else the rules of conf (hosp_restore, restore_wait, restore_max). r = the last
-- water run (its patients and sources). BUG-540: entries older than hrm_expire are forgotten; a 'dry' entry and a zoneless
-- hospital room ('room') come back only with accepted water within near of the old room, force or not (without it
-- remove_dry would take the zone away again under a new id). Returns {done = {zone ids drawn}, left = n, fail = {text}}.
function M.restore(K, c, r, p, now, opt)
  opt = opt or {}
  local res = {done = {}, left = 0, fail = {}}
  local list = json.array({})
  for _, e in ipairs(type(p.hrm) == 'table' and p.hrm or {}) do
    if now - (math.tointeger(e.t) or now) < c.hrm_expire then
      list[#list + 1] = e
    else
      K.log('info', 'water: remembered hospital zone %s (location %s, %s) forgotten after %d days (BUG-540)', tostring(e.id),
            tostring(e.loc), tostring(e.why), c.hrm_expire // DAY)
    end
  end
  if type(p.hrm) == 'table' and #list ~= #p.hrm then p.hrm = list end
  local rooms = {}
  if r and (opt.force or #r.hosp == 0) and (opt.force or c.hosp_restore ~= false) then rooms = M.orphan_rooms(K, r) end
  if #rooms == 0 then p.ot = nil elseif not opt.force then p.ot = p.ot or now end
  if (#list == 0 and #rooms == 0) or not M.can('hospital_restore') then res.left = #list; return res end
  if not opt.force and c.hosp_restore == false then res.left = #list; return res end
  local worst = 0
  for _, pt in ipairs(r and r.patients or {}) do if pt.thirst > worst then worst = pt.thirst end end
  local all = {}
  for _, e in ipairs(list) do all[#all + 1] = e end
  for _, e in ipairs(rooms) do all[#all + 1] = e end
  local keep = json.array({})
  for _, e in ipairs(all) do
    local take = opt.loc == nil or e.loc == opt.loc
    local age = now - (math.tointeger(e.t) or (e.orph and p.ot) or now)
    local dry = e.why == 'dry' or e.why == 'room'
    local wet_ok, nearest = true, nil
    if dry then
      if r ~= nil then wet_ok, nearest = served(K, c, r, e) else wet_ok = false end
      wet_ok = wet_ok == true
    end
    local ready = opt.force == true
    if not ready and age >= c.restore_wait then
      if dry then
        ready = wet_ok
      else
        ready = worst <= c.patient_thirst or age >= c.restore_max
      end
    end
    local drawn = false
    local label = e.orph and 'of the hospital room' or tostring(e.id)
    if take and ready and dry and not wet_ok then
      res.fail[#res.fail + 1] = string.format('zone %s (location %d): dry: no accepted water within %d tiles of the old room (nearest: %s); '
                                              .. 'it comes back once water stands near%s', label, e.loc, c.near,
                                              nearest and string.format('%s %d at %d,%d,%d, %d tiles', nearest.s.kind, nearest.s.id,
                                                                        nearest.s.x, nearest.s.y, nearest.s.z, nearest.d) or 'none accepted',
                                              e.orph and '' or string.format(', the memory is forgotten after %d d', c.hrm_expire // DAY))
    elseif take and ready then
      local ok, got = K.act.hospital_restore(e)
      if ok then
        drawn = true
        if got == 'present' then
          res.done[#res.done + 1] = e.id
        else
          for _, id in ipairs(type(got) == 'table' and got.ids or {}) do res.done[#res.done + 1] = id end
        end
      else
        res.fail[#res.fail + 1] = string.format('zone %s (location %d): %s', label, e.loc, tostring(got))
        if tostring(got):find('^no hospital location') then drawn = true end   -- the location is gone: nothing to come back to
      end
    end
    if not drawn and not e.orph then keep[#keep + 1] = e end
  end
  p.hrm = keep
  res.left = #keep
  if #res.done > 0 then
    K.log('warn', 'water: hospital zone(s) %s drawn again at their old location (BUG-539)%s', table.concat(res.done, ','),
          #keep > 0 and (', ' .. #keep .. ' still waiting') or '')
  end
  return res
end

---------------------------------------------------------------- dry hospital removal (BUG-034)
-- Run 11 (Kilrudrabed site98, y439 spring): 5 bedridden patients died of thirst (75,000) and 8 more were over 40,000 in a
-- hospital of 4 locations and 5 zones without accepted water, while HOSPITAL_DRY had said so for a long time and nothing
-- acted. The game session removed the 5 zones by hand (zones screen) and GiveWater jobs brought water to the patients
-- again (4 at once); Run 9 (FR-34): deleting the hospital zone made the survivor stand up, drink and eat. The DF rule
-- both rest on, as far as the live notes show it (bugs/BUG-034): a patient in a hospital without accepted water gets no
-- water (GiveWater cancelled "No water source" in Run 9, posted and never done in L5); without the hospital zone he does.
-- So while a patient is over patient_thirst, every zone of a hospital location none of whose zones is served goes; a
-- location with a served zone keeps all of its zones. The location itself stays (an empty entry on the locations screen).
-- Returns {zones, over} when zones were removed in this run, else nil.
local function remove_dry(K, c, r, p, T)
  if not removes(c) then return nil end
  local over = {}
  for _, pt in ipairs(r.patients) do if pt.thirst > c.patient_thirst then over[#over + 1] = pt end end
  if #over == 0 then return nil end
  local wet_loc = {}
  for _, h in ipairs(r.hosp) do if served(K, c, r, h) then wet_loc[h.loc] = true end end
  local zones, locs, seen, failed, first = {}, {}, {}, 0, nil
  for _, h in ipairs(r.hosp) do
    if not wet_loc[h.loc] and #zones + failed < c.remove_per_run then
      if K.act.hospital_remove(h.id) then             -- a refusal is an ACT_FAIL (B); the next run tries again
        M.remember(p, h, K.now().tick, 'dry')
        zones[#zones + 1], first = h.id, first or h
        if not seen[h.loc] then seen[h.loc], locs[#locs + 1] = true, h.loc end
      else
        failed = failed + 1
      end
    end
  end
  if #zones == 0 then return nil end
  table.sort(over, function(a, b) return a.thirst > b.thirst end)
  local ids = {}
  for i = 1, math.min(8, #over) do ids[i] = over[i].id end
  local best
  for _, s in ipairs(r.sources) do
    if s.wet and not s.emerg then
      local d = dist_box(s.x, s.y, s.z, first)
      if not best or d < best.d then best = {d = d, s = s} end
    end
  end
  local src = best and string.format('nearest accepted water %d,%d,%d (%d tiles)', best.s.x, best.s.y, best.s.z, best.d)
              or 'no accepted water on the map'
  local function list(t)
    local o = {}
    for i = 1, math.min(6, #t) do o[i] = fmt(t[i]) end
    return table.concat(o, ',') .. (#t > 6 and '+' or '')
  end
  local top = over[1]
  K.emit('HOSPITAL_REMOVED', 'A',
         trunc(string.format('removed %d dry hospital zone(s) %s (location %s): %d patient(s) over thirst %d, unit %d at '
                             .. '%d; %s; water before a new hospital', #zones, list(zones), list(locs), #over,
                             c.patient_thirst, top.id, top.thirst, src), 200),
         {zones = zones, locs = locs, units = ids, n = #over, thirst = top.thirst, patients = #r.patients,
          give = r.give, failed = failed, near = c.near, d = best and best.d or nil,
          src = best and {best.s.x, best.s.y, best.s.z} or nil})
  K.log('warn', 'water: removed hospital zone(s) %s of location(s) %s (no accepted water within %d tiles): %d patient(s) '
        .. 'over thirst %d (unit %d at %d), %d GiveWater job(s) now; %s', list(zones), list(locs), c.near, #over,
        c.patient_thirst, top.id, top.thirst, r.give, src)
  p.rm = {t = T.tick, zones = zones, locs = locs, n = #over, tmax = top.thirst, give = r.give}
  return {zones = zones, over = over}
end

-- the accepted sources (a well over water, a deep Water Source zone), nearest to the first hospital zone (else the
-- citizens' median) first, at most SRC_MAX as [x, y, z] (state water.src: plan propose/check, BUG-034)
local function src_list(r)
  local ref = r.hosp[1]
  if not ref and #r.home > 0 then
    local mx, my, mz = median(r.home, 'x'), median(r.home, 'y'), median(r.home, 'z')
    ref = {x1 = mx, y1 = my, x2 = mx, y2 = my, z = mz}
  end
  local l = {}
  for _, s in ipairs(r.sources) do
    if s.wet and not s.emerg then l[#l + 1] = {s = s, d = ref and dist_box(s.x, s.y, s.z, ref) or 0} end   -- BUG-425
  end
  table.sort(l, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.s.id < b.s.id
  end)
  local out, lbl = json.array{}, json.array{}
  for i = 1, math.min(M.SRC_MAX, #l) do
    local s = l[i].s
    out[i] = json.array{s.x, s.y, s.z}
    if i <= M.SRC_LBL then                                     -- BUG-040: the nearest ones (state size)
      lbl[i] = trunc(string.format('%s %d', s.kind, s.id) .. (s.inn and (' in ' .. s.inn) or ''), 32)
    end
  end
  return out, lbl, l[1] and l[1].s or nil
end

---------------------------------------------------------------- BUG-040: cisterns that stay dry
-- Run 11 (Kilrudrabed site98, y453): the cisterns y450s0b0 and y452s1b0 were PROJECT_DONE and their wells never held
-- water: the fort had no revealed open water (water NO since the run began), so nothing could fill them, and nobody said
-- so. A cistern room of the manifest (merged when its project is done) whose built well stays dry for cistern_dry_days
-- is reported once per dry spell (CISTERN_DRY, B; kern.log): what should fill it (fill: pond = bucket-fed by its pond
-- zone, pond_removed = pond_loops removed that zone as a loop, pipe = its floodgate waits for the well room's lever,
-- none), the nearest accepted water to carry from. Its project id from the runner's kept boxes, the pipe from its bp
-- file (runner.kept_in, runner.bp_params; read-only, only when reporting).
local function cistern_dry(K, c, r, p, now)
  p.cdry = json.object(type(p.cdry) == 'table' and p.cdry or {})
  local seen = {}
  for _, rm in ipairs(K.manifest().rooms or {}) do
    local b = rm.tpl == 'cistern' and type(rm.bbox) == 'table' and type(rm.id) == 'string' and rm.bbox
    if b and math.tointeger(b[1]) and math.tointeger(b[6]) then
      local well
      for _, s in ipairs(r.sources) do
        if s.kind == 'well' and s.built and s.z == b[3] and s.x >= b[1] and s.x <= b[4] and s.y >= b[2]
           and s.y <= b[5] then well = s end
      end
      local rec = p.cdry[rm.id]
      if well then seen[rm.id] = true end
      if well and (well.wet or well.water) then              -- BUG-263: a loop well holds water all the same
        if type(rec) == 'table' and rec.said then
          K.log('info', 'water: cistern %s: its well %d holds water again', rm.id, well.id)
        end
        p.cdry[rm.id] = nil
      elseif well and type(rec) ~= 'table' then
        p.cdry[rm.id] = {t = now}
      elseif well and not rec.said and now - (math.tointeger(rec.t) or now) >= c.cistern_dry_days * DAY then
        rec.said = now
        local box = {x1 = b[1], y1 = b[2], x2 = b[4], y2 = b[5], z = b[3]}
        local fill, pond = 'none', nil
        for _, pd in ipairs(r.ponds) do
          if pd.z == b[3] and pd.x1 >= b[1] and pd.x2 <= b[4] and pd.y1 >= b[2] and pd.y2 <= b[5] then
            fill, pond = 'pond', pd.id
          end
        end
        for _, e in ipairs(fill == 'none' and type(p.prm) == 'table' and p.prm or {}) do
          if e[4] == b[3] and e[2] >= b[1] and e[2] <= b[4] and e[3] >= b[2] and e[3] <= b[5] then
            fill, pond = 'pond_removed', e[1]
          end
        end
        local okk, proj = K.call('runner', 'kept_in', b)
        proj = okk and type(proj) == 'string' and proj or nil
        if fill == 'none' and proj then
          local okp, prm = K.call('runner', 'bp_params', proj)
          if okp and type(prm) == 'table' and type(prm.path) == 'string' and prm.path ~= '' then fill = 'pipe' end
        end
        local best
        for _, s in ipairs(r.sources) do
          if s.wet and s ~= well then
            local d = dist_box(s.x, s.y, s.z, box)
            if not best or d < best.d then best = {d = d, s = s} end
          end
        end
        local how = ({pond = string.format('bucket-fed (pond zone %s)', tostring(pond)),
                      pond_removed = string.format('bucket-fed, its pond zone %s removed as a pond loop (its own well '
                                                   .. 'fed it)', tostring(pond)),
                      pipe = 'piped: its floodgate waits for the lever (link it, pull it once)',
                      none = 'no pond zone, no pipe: nothing fills it'})[fill]
        local carry = best and string.format('carry from: %s %d at %d,%d,%d (%d tiles)', best.s.kind, best.s.id,
                                             best.s.x, best.s.y, best.s.z, best.d)
                      or 'no accepted water to carry from (no revealed water source)'
        local days = (now - (math.tointeger(rec.t) or now)) // DAY
        local msg = string.format('cistern %s done, its well %d at %d,%d,%d dry for %d days: %s; %s', proj or rm.id,
                                  well.id, well.x, well.y, well.z, days, how, carry)
        local tail = '; no drink for a hospital or the refuge'
        if #msg + #tail <= 200 then msg = msg .. tail end
        K.emit('CISTERN_DRY', 'B', trunc(msg, 200),
               {room = trunc(rm.id, 60), proj = proj, well = well.id, pos = {well.x, well.y, well.z}, days = days,
                fill = fill, pond = pond, src = best and {best.s.x, best.s.y, best.s.z} or nil, d = best and best.d or nil})
        K.log('warn', 'water: %s', msg)
      end
    end
  end
  for id in pairs(p.cdry) do if not seen[id] then p.cdry[id] = nil end end
end

---------------------------------------------------------------- BUG-036: the hospital outside the core
-- Run 11 siege 9 (y445): two cave dragons struck down 8 citizens in the BREACH, 7 of them patients in hospital beds; a
-- lying patient cannot walk to the refuge (only a rescue or hauling moves him), so the hospital (its zone and beds) has to
-- lie in Tiefe+, or at least in Kern+ behind the seal, AND next to accepted water (BUG-034). Per hospital zone: the tiles
-- of its rect (<= HOSP_TILES, evenly sampled) on neither burrow (state water.hosp_out, readiness R0 hospital_out); in a fight
-- (SIEGE/BREACH) once the patients outside the burrow the civ alert confines to (PATIENTS_OUT, B; Kern+ and the refuge
-- while it is silent). Reads burrow tiles and the census patients only; moves nobody.
M.HOSP_TILES = 100         -- tiles looked at per hospital zone (an even sample of a bigger one)
local FIGHT = {SIEGE = true, BREACH = true}

local function hospital_out(r, kern, refuge, kname, rname)
  local zones = {}
  if kern or refuge then
    for _, h in ipairs(r.hosp) do
      local area, step = (h.x2 - h.x1 + 1) * (h.y2 - h.y1 + 1), 1
      while area > M.HOSP_TILES * step * step do step = step + 1 end     -- a big zone: an even sample of its tiles
      local n, out = 0, 0
      for y = h.y1, h.y2, step do
        for x = h.x1, h.x2, step do
          n = n + 1
          if not (on_burrow(kern, x, y, h.z) or on_burrow(refuge, x, y, h.z)) then out = out + 1 end
        end
      end
      if out > 0 then
        zones[#zones + 1] = {id = h.id, loc = h.loc, x = (h.x1 + h.x2) // 2, y = (h.y1 + h.y2) // 2, z = h.z,
                             tiles = out, of = n}
      end
    end
  end
  return {n = #zones, total = #r.hosp, zones = zones, kern = kname, refuge = rname}
end

local function patients_out(K, r, kern, refuge, kname, rname, ho)
  local mode = K.mode()
  if not FIGHT[mode] then st.pout = nil; st.pdec = nil; return end
  if #r.patients == 0 then return end
  local okn, names = K.call('siege', 'alert_names')
  names = okn and type(names) == 'table' and names or {}
  local b1 = type(names[1]) == 'string' and burrow_named(names[1]) or nil
  local bs, label = {kern, refuge}, kname .. '/' .. rname
  if b1 then bs, label = {b1}, names[1] end
  local out, ids, at = {}, {}, {}
  for _, pt in ipairs(r.patients) do
    local inb = false
    for _, b in ipairs(bs) do if on_burrow(b, pt.x, pt.y, pt.z) then inb = true; break end end
    if not inb then
      out[#out + 1] = pt
      if #ids < 20 then ids[#ids + 1] = pt.id end
      if #at < 3 and pt.x then at[#at + 1] = string.format('%d at %d,%d,%d', pt.id, pt.x, pt.y, pt.z) end
    end
  end
  if #out == 0 then return end
  local cs = st.care
  if not st.pout then                                   -- the plain event: once per fight
    st.pout = K.now().tick
    local tail = ho.n > 0 and string.format('; the hospital lies outside %s/%s: move it into %s next to accepted water',
                                            kname, rname, rname)
                 or '; plan the hospital inside the refuge'
    -- BUG-330: what the care burrow does for them (open, or why not; it opens for a patient over care_thirst)
    local care
    if cs and cs.on then care = M.CARE .. ' open to them'
    elseif cs and cs.why == M.NOT_YET then
      care = string.format('%s opens to one over thirst %d with no hostile near', M.CARE, cs.th or 0)
    elseif cs then care = 'no ' .. M.CARE .. ': ' .. tostring(cs.why) end
    local msg = string.format('%s: %d of %d patients lie outside the alert burrow %s (%s): they cannot walk there, only a '
                              .. 'rescue moves them%s', mode, #out, #r.patients, label, table.concat(at, ', '), tail)
    if care and #msg + #care + 2 <= 200 then msg = msg .. '; ' .. care end
    K.emit('PATIENTS_OUT', 'B', trunc(msg, 200), {n = #out, patients = #r.patients, burrow = trunc(label, 60), units = ids,
                                                  mode = mode, hosp_out = ho.n, care = care and trunc(care, 80) or nil})
    K.log('warn', 'water: %s', msg)
  end
  -- BUG-559 (Run 16b i2 y402: 3 patients outside the BREACH alert burrow died of thirst, PATIENTS_OUT was a plain event): a
  -- patient over care_thirst whom the care burrow does not reach is a decision (urgent): the reason it is closed, the commands.
  -- Judged EVERY pass, not at the first one only: in y402 the patients were not yet thirsty when the siege began and died of
  -- thirst later; each patient is decided once per fight (st.pdec), a new one gets his own decision
  local c = M.conf(K)
  st.pdec = st.pdec or {}
  local dry, dids = {}, {}
  for _, pt in ipairs(out) do
    if (pt.thirst or 0) >= c.care_thirst and not st.pdec[pt.id] then
      dry[#dry + 1] = pt; if #dids < 20 then dids[#dids + 1] = pt.id end
    end
  end
  if #dry > 0 and not (cs and cs.on) then
    for _, pt in ipairs(dry) do st.pdec[pt.id] = K.now().tick end
    local why = cs and cs.why or 'water has not planned it yet'
    local q = string.format('%s: %d patient(s) over thirst %d lie outside %s and no water reaches them (%s): a rescue, or '
                            .. 'the hospital water inside the burrow', mode, #dry, c.care_thirst, label, why)
    local cmds = {'dfllm cmd inspect what=hospital', 'dfllm cmd inspect what=water_sources'}
    for i = 1, math.min(#dids, 2) do cmds[#cmds + 1] = 'dfllm cmd inspect what=unit key=' .. fmt(dids[i]) end
    K.emit('DECISION_NEEDED', 'A', trunc('patient_out: ' .. q, 200),
           {id = 'patient_out', q = trunc(q, 200), units = dids, cmds = cmds, mode = mode, why = trunc(tostring(why), 80)})
  end
end

---------------------------------------------------------------- BUG-054: caregivers scale with the patients
-- Run 11 y497 (the game session's notes 18, 24): patient_thirst said "water, buckets and caregivers present" while 3-5
-- patients stood at thirst 30,000-40,293 with 24-27 of 62 buckets free and 4 caregivers; five of them died of thirst
-- together (75,000, hunger 80-119k) in a fort that reported "hospital ok", and the fort went from 49 citizens to 1.
-- What the code proves: nothing in the kernel ever gave the FEED_WATER_CIVILIANS labor to anybody (it only counts the
-- citizens who have it, `carer`), so the number of caregivers was whatever the game's own Orderlies work detail held;
-- the cause text only said "no caregiver" for ZERO of them, 4 for 5 patients counted as "present"; and a wet hospital
-- got no action at all: the only act was the removal of a DRY hospital's zones (remove_dry) and one weekly line.
-- Now: want = carers_per_patient per patient (carers_min .. carers_max, + carers_urgent while a patient is over
-- thirst_alarm); missing caregivers are added to the Orderlies work detail (the work details screen: act.work_detail,
-- the best candidate first: idle, then nearest the hospital; never a soldier, a dwarf in a mood, a noble, a child or
-- a miner/woodcutter/hunter); the ones added leave again carers_hold_days after the last patient. Not decided offline:
-- why the game's own jobs did not keep up (busy carers, no job posted, unreachable water): `give_jobs` and the
-- caregivers' state (idle, GiveWater jobs running/open) go into PATIENT_DYING and inspect water_sources.
M.CARER_DETAIL = 'Orderlies'
M.POOL_MAX = 200
local NO_WAIT = 7 * DAY                 -- a missing Orderlies detail is not asked for again for a week

function M.idle(u)
  local ok, yes = pcall(function() return u.job == nil or u.job.current_job == nil end)
  return ok and yes == true
end

-- a citizen the kernel may ask to carry water: adult, no squad, no mood, no noble post, no tool labor (Miners,
-- Woodcutters and Hunters are specialists), not a patient (the caller)
function M.carer_ok(u)
  local ok, yes = pcall(function()
    if dfhack.units.isDead(u) or not dfhack.units.isAdult(u) then return false end
    if (u.military.squad_id or -1) >= 0 then return false end
    if (u.mood or -1) >= 0 then return false end
    for _, name in ipairs({'MINE', 'CUTWOOD', 'HUNT'}) do
      local l = df.unit_labor and df.unit_labor[name]
      if l ~= nil and u.status.labors[l] == true then return false end
    end
    return true
  end)
  if not (ok and yes == true) then return false end
  local okn, np = pcall(dfhack.units.getNoblePositions, u)
  if okn and type(np) == 'table' and #np > 0 then return false end
  return true
end

-- GiveWater/GiveFood jobs on the job list: open (no worker) and running; nil when this DF has neither job type.
-- One bounded pass, only called while a patient is thirsty (water's own cadence, a game day)
function M.give_jobs()
  local sc = M.job_scan()
  if sc == nil then return nil end
  if sc.read == false then return 0, 0 end
  return sc.w_open + sc.f_open, sc.w_run + sc.f_run
end

-- BUG-104 (Run 14 note 79: 'GiveWater added=0 with 86-119 buckets and 7-9 caregivers'): the kernel creates no job, the game does;
-- `added` of the DECISION_NEEDED counts the caregivers the kernel put into the Orderlies work detail (M.carers), so 0 is the
-- right answer once enough hold the labor. What decides whether anybody carries water is the game's job list: this is its
-- census, GiveWater (w_) and GiveFood (f_) jobs open (no worker) and running. With `p` the ids of the open GiveWater jobs are
-- remembered (p.gj, id -> tick first seen, at most M.GJ_MAX) and `stuck` counts those open for `days` game days or more
-- (`oldest` = the oldest one's ticks). A job's pos is not read: a running job may well have pos -30000 (the note), so that
-- says nothing. nil: this DF has neither job type; read = false: the job list could not be read.
M.GJ_MAX = 60
function M.job_scan(p, now, days)
  local function types(names)
    local t = {}
    for _, n in ipairs(names) do
      local v = df.job_type and df.job_type[n]
      if type(v) == 'number' then t[v] = true end
    end
    return t
  end
  local water, food = types({'GiveWater', 'GiveWater2'}), types({'GiveFood'})
  if next(water) == nil and next(food) == nil then return nil end
  local sc = {w_open = 0, w_run = 0, f_open = 0, f_run = 0, stuck = 0, oldest = 0, read = true, w_workers = {}}
  local seen, i = {}, 0
  local ok = pcall(function()
    local link = df.global.world.jobs.list.next
    while link and i < 20000 do
      local j = link.item
      local isw = j and water[j.job_type] == true
      if j and (isw or food[j.job_type]) then
        local okw, w = pcall(dfhack.job.getWorker, j)
        local open = okw and w == nil
        local k = (isw and 'w_' or 'f_') .. (open and 'open' or 'run')
        sc[k] = sc[k] + 1
        if isw and open and math.type(j.id) == 'integer' then seen[string.format('%d', j.id)] = true end
        -- BUG-383: who carries the running GiveWater jobs (at most 8 ids), for the stale-job release (M.restale)
        if isw and not open and okw and #sc.w_workers < 8 then
          local okid, wid = pcall(function() return math.type(w) == 'integer' and w or w.id end)
          if okid and math.type(wid) == 'integer' then sc.w_workers[#sc.w_workers + 1] = wid end
        end
      end
      link, i = link.next, i + 1
    end
  end)
  if not ok then sc.read = false; return sc end
  if p and now and days then
    local gj, n = p.gj, 0
    for _ in pairs(gj) do n = n + 1 end
    for sid in pairs(seen) do
      if gj[sid] == nil and n < M.GJ_MAX then gj[sid], n = now, n + 1 end
      local age = gj[sid] and now - gj[sid] or 0
      if age >= days * DAY then sc.stuck = sc.stuck + 1 end
      if age > sc.oldest then sc.oldest = age end
    end
    for sid in pairs(gj) do if not seen[sid] then gj[sid] = nil end end      -- taken, done or gone
  end
  return sc
end

local function plural(n, one, many) return string.format('%d %s', n, n == 1 and one or many) end

-- BUG-104: why no caregiver carries water to the patients over the alarm, in counts, from what is read: the civ alert
-- (the burrow it holds the citizens in, the patient's tile), the caregivers' walk groups against the thirstiest patient
-- (snapshot.reach, canWalkBetween: unknown counts as reachable), the job list (M.job_scan), the buckets. Returns
-- {key, reason (short), txt (counts), short (counts without the buckets), open, run, stuck, reach, idle, carers}. The first
-- of: alert (confined away from the patient), noreach (none walks to him), stuck / open (jobs nobody takes), nojob (the game
-- posts none), run (jobs run). Live data that decides the rest: `inspect what=hospital` and kern.log 'water:' lines.
-- BUG-449 (Run 16a i1 Syrupobeyed y384-y386: two patients died of thirst in the same bed area 94,113,135 under '1-4 GiveWater jobs running
-- 25+ days without effect', hospital ok, 25 free buckets, the nearest accepted water a zone at 106,109,139 four levels up): the verdict
-- `run` said nothing about WHERE the water is. Does an accepted source (a wet well or Water Source zone, no emergency well) lie on the walk
-- group of the patient (snapshot.groups with the neighbour lookup: a zone tile is water, no floor)? {ok, s, d} with the nearest source
-- on his group, else the nearest overall with ok false; nil when unknown (no source, no group read)
function M.src_reach(K, r, top)
  if not (top and top.x) then return nil end
  local list = {}
  for _, s in ipairs(r.sources or {}) do
    if s.wet and not s.emerg and s.x then
      list[#list + 1] = {s = s, d = math.max(math.abs(s.x - top.x), math.abs(s.y - top.y), math.abs(s.z - top.z))}
    end
  end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.d < b.d end)
  local pts = {{x = top.x, y = top.y, z = top.z}}
  for i = 1, math.min(8, #list) do pts[#pts + 1] = {x = list[i].s.x, y = list[i].s.y, z = list[i].s.z} end
  -- review of round 28: the patient's group first, then the zone / well tiles with it as `prefer` (BUG-390, as economy does): a zone
  -- centre is water, no floor, and its neighbour lookup answered the first walkable neighbour, often another group than the one the
  -- patient shares with it: a false 'no accepted water on his group'
  local ok0, g0 = K.call('snapshot', 'groups', {pts[1]}, true)
  if not ok0 or type(g0) ~= 'table' or type(g0[1]) ~= 'number' or g0[1] <= 0 then return nil end
  local ok, gs = K.call('snapshot', 'groups', pts, true, {[g0[1]] = true})
  if not ok or type(gs) ~= 'table' or type(gs[1]) ~= 'number' or gs[1] <= 0 then return nil end
  local known = false
  for i = 2, #pts do
    local g = gs[i]
    if type(g) == 'number' and g > 0 then
      known = true
      if g == gs[1] then return {ok = true, s = list[i - 1].s, d = list[i - 1].d, g = gs[1]} end
    end
  end
  if not known then return nil end
  return {ok = false, s = list[1].s, d = list[1].d, g = gs[1], gs = gs[2]}
end

-- BUG-449: the commands that can be run for a patient whose water does not come (patient_thirst / PATIENT_DYING `cmds`)
function M.patient_cmds(gv, top)
  local out = json.array{}
  if top and top.x and gv and (gv.key == 'srcreach' or gv.srcreach) then
    out[#out + 1] = string.format('dfllm bp sites cistern --near %d,%d,%d --within 15 --fresh', top.x, top.y, top.z)
  end
  if top and top.id then out[#out + 1] = string.format('dfllm cmd inspect what=unit key=%d', top.id) end
  out[#out + 1] = 'dfllm cmd inspect what=hospital'
  out[#out + 1] = 'dfllm cmd inspect what=reach'
  out[#out + 1] = 'dfllm cmd inspect what=water_sources'
  return out
end

function M.give_diag(K, c, r, sc, bfree, top)
  local gv = {carers = #r.carers, idle = r.carers_idle, key = 'unreadable'}
  local ok_job = sc ~= nil and sc.read ~= false
  local wet_any = false
  for _, s in ipairs(r.sources or {}) do if s.wet then wet_any = true end end
  gv.open, gv.run, gv.stuck = ok_job and sc.w_open or nil, ok_job and sc.w_run or nil, ok_job and sc.stuck or nil
  -- the caregivers' reach to the thirstiest patient
  if top and top.x and #r.cpos > 0 then
    local n, ri = 0, 0
    for _, cp in ipairs(r.cpos) do
      local okr, yes = K.call('snapshot', 'reach', {x = cp.x, y = cp.y, z = cp.z}, {x = top.x, y = top.y, z = top.z})
      if not okr or yes ~= false then n = n + 1; if cp.idle then ri = ri + 1 end end
    end
    gv.reach, gv.reach_idle = n, ri
  end
  -- the civ alert: the caregivers wait in its burrow; a patient outside it is out of their reach
  local alert
  local okc, idx = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  if okc and idx ~= nil and idx ~= 0 and top and top.x then
    local okn, names = K.call('siege', 'alert_names')
    names = okn and type(names) == 'table' and names or {}
    local bs = {}
    for _, nm in ipairs(names) do
      if nm ~= M.CARE then bs[#bs + 1] = {n = nm, b = type(nm) == 'string' and burrow_named(nm) or nil} end
    end
    if #bs == 0 then bs = M.alert_burrows(idx, true) end   -- BUG-153: siege's list is runtime only; the game's alert is not
    local inside = #bs == 0
    for _, e in ipairs(bs) do
      if e.b and on_burrow(e.b, top.x, top.y, top.z) then inside = true end
    end
    if not inside then alert = bs[1].n or '?' end
  end
  local sreach = wet_any and top and top.x and not alert and M.src_reach(K, r, top) or nil   -- BUG-449
  local jobs_t = ok_job and string.format('jobs %d open/%d running', gv.open, gv.run) or 'jobs unreadable'
  gv.jobs_t = jobs_t
  gv.reach_t = string.format('%d idle, %s reach', gv.idle, gv.reach and tostring(gv.reach) or '?')
  gv.short = string.format('%s, carers %d (%s)', jobs_t, gv.carers, gv.reach_t)
  gv.txt = string.format('%s, buckets %d free of %d', gv.short, bfree, r.buckets)
  -- BUG-434: how far the carriers have to walk for the thirstiest patient's water (nil: no accepted source)
  local pf = math.tointeger(c.patient_far) or 0
  gv.sd = top and top.x and M.source_dist(r, top) or nil
  if alert then
    gv.key, gv.reason = 'alert', 'the civ alert holds the caregivers in ' .. alert .. ', the patient lies outside'
    -- BUG-330 (Earthboat y385: 'the civ alert holds the caregivers in Tiefe+' while no water was accepted at all): both
    -- causes; the care burrow (M.care_step) opens the way out to him, never water that does not exist
    local cs = st.care
    if not wet_any then
      gv.nowater = true
      gv.reason = gv.reason .. ', and no accepted water (no well over water, no Water Source zone): nothing to carry'
    elseif cs and cs.on and cs.ids[top.id] then
      gv.reason = gv.reason .. string.format('; %s opened to him (his tile and the water)', M.CARE)
    elseif cs and cs.why then
      gv.reason = gv.reason .. '; ' .. M.CARE .. ' not opened: ' .. cs.why
    end
  elseif gv.reach == 0 then
    gv.key, gv.reason = 'noreach', string.format('no caregiver reaches the patient (0 of %d)', #r.cpos)
  elseif not ok_job then
    gv.key, gv.reason = 'unreadable', 'the GiveWater jobs cannot be read'
  elseif not wet_any and gv.run == 0 then
    -- BUG-324 (Earthboat y385: '1 GiveWater job open, none taken by 53 idle'): idle carers were never the cause; the game
    -- takes the water for GiveWater from a well or a Water Source zone, and none was accepted
    gv.key = 'nowater'
    gv.reason = string.format('no accepted water (no well over water, no Water Source zone): %s', gv.open > 0
                              and plural(gv.open, 'GiveWater job', 'GiveWater jobs') .. ' open without a source'
                              or 'no GiveWater job without a source')
  elseif gv.stuck > 0 then
    gv.key, gv.reason = 'stuck', string.format('%s open %d+ days', plural(gv.stuck, 'GiveWater job', 'GiveWater jobs'),
                                               c.give_stuck_days)
  elseif gv.open > 0 and gv.run == 0 then
    gv.key = 'open'
    gv.reason = string.format('%s open, none taken by %s', plural(gv.open, 'GiveWater job', 'GiveWater jobs'),
                              gv.idle > 0 and string.format('%d idle', gv.idle) or 'a caregiver (none idle)')
  elseif gv.run > 0 then
    gv.key, gv.reason = 'run', plural(gv.run, 'GiveWater job', 'GiveWater jobs') .. ' running'
  else
    gv.key, gv.reason = 'nojob', 'the game posts no GiveWater job'
  end
  -- BUG-449 (review of round 28): no accepted water on the patient's walk group. It is told in addition to stuck / open / run: those
  -- verdicts feed the noeffect release (give_effect, BUG-383 restale) and must not be masked; only when the game posts no job at
  -- all (`nojob`) is it the verdict itself
  if sreach and sreach.ok == false then
    local sr = sreach
    gv.srcreach = {g = sr.g, gs = sr.gs, d = sr.d, kind = sr.s.kind, id = sr.s.id}
    local txt = string.format('no accepted water on the walk group %d of the patient: the nearest, %s %d at %d,%d,%d (%d tiles), lies on group %s '
                              .. '(the carriers cannot fetch it): a cistern beside him', sr.g, sr.s.kind, sr.s.id or -1, sr.s.x, sr.s.y,
                              sr.s.z, sr.d, tostring(sr.gs))
    if gv.key == 'nojob' then gv.key, gv.reason = 'srcreach', txt
    else gv.reason = gv.reason .. '; ' .. txt end
  end
  -- BUG-434: the verdict stays (a stale job is still a stale job); the distance is added to it
  if pf > 0 and gv.sd and gv.sd > pf and gv.key ~= 'nowater' then
    gv.far = gv.sd
    gv.reason = gv.reason .. string.format('; nearest accepted water %d tiles from him (> %d): the carriers walk that far, '
                                           .. 'barrels are no water, a cistern near the patients', gv.sd, pf)
  end
  return gv
end

-- BUG-434: the Chebyshev distance from a patient to the nearest accepted source (a wet well or Water Source zone, not an emergency
-- well) of this run; nil when there is none
function M.source_dist(r, pt)
  local best
  for _, s in ipairs(r.sources or {}) do
    if s.wet and not s.emerg and s.x then
      local d = math.max(math.abs(s.x - pt.x), math.abs(s.y - pt.y), math.abs(s.z - pt.z))
      if not best or d < best then best = d end
    end
  end
  return best
end

-- BUG-343 (Run 15 Guildcleans y386-y390: 13 patients dead of thirst at 75,000 while PATIENT_DYING said '1-10 GiveWater
-- jobs running', verdict `run`, i.e. nothing to do): a job that runs for days while the same patient's thirst only climbs
-- brings no water (a drink resets the timer). M.NOEFFECT_DAYS after the first `run` verdict for the thirstiest patient
-- without his thirst ever falling (p.grun {u, t, th}) the verdict is `noeffect`, naming the accepted water nearest the
-- hospital the carriers would fill at (src, served()'s best: {d, s}); any other verdict, another top patient or a drink
-- starts anew. Report only: what the carrier really does with the bucket is the game's (kern.log, inspect water_sources)
M.NOEFFECT_DAYS = 2
M.STARVE_HUNGER = 50000                       -- BUG-343 review: DF's "hungry"; the dead lay at 51,683-98,595
function M.give_effect(p, gv, top, now, src)
  local g = type(p.grun) == 'table' and p.grun or nil
  if gv.key ~= 'run' or not top or not top.id then p.grun = nil; return gv end
  if not g or math.tointeger(g.u) ~= top.id or top.thirst < (math.tointeger(g.th) or 0) then
    p.grun = {u = top.id, t = now, th = top.thirst}
    return gv
  end
  local dt = now - (math.tointeger(g.t) or now)
  -- climbing: at least half the timer's tick rate since then (a timer that stands still is no proof of anything)
  if dt // DAY < M.NOEFFECT_DAYS or top.thirst - (math.tointeger(g.th) or 0) < dt // 2 then return gv end
  local days = dt // DAY
  local s = src and src.s
  local at = s and string.format('%s %d at %d,%d,%d, %d tiles', s.kind, s.id, s.x, s.y, s.z, src.d) or 'none accepted'
  -- BUG-343 review: the dead of Guildcleans and Drillchamber starved as well (hunger 51,683-98,595 at 75,000 thirst): no
  -- food reached them either, so the care fails, not the water (GiveFood is the same caregivers' work)
  local hu = math.tointeger(top.hunger) or 0
  local why = hu >= M.STARVE_HUNGER and string.format('hunger %d too: no food reaches him either, the care fails, not '
                                                      .. 'the water', hu) or 'a dry well, or the carriers cancel?'
  gv.key = 'noeffect'
  gv.reason = string.format('%s running %d+ days without effect (unit %d thirst %d -> %d; nearest water: %s): %s',
                            plural(gv.run, 'GiveWater job', 'GiveWater jobs'), days, top.id,
                            math.tointeger(g.th) or -1, top.thirst, at, why)
  return gv
end

-- BUG-383 (Run 16b i2 y381: 26275 thirst 30,076 -> 60,594 -> dead at 75,001 under '1 GiveWater job running 25+ days without
-- effect' (BUG-343's verdict was only a report): the job the game keeps for a patient can hang on its carrier for ever.
-- The kernel never removes a job (DESIGN 5.9), but it may take the carrier off the Orderlies detail: his labor goes, the game
-- drops the job and posts a new one for the patient; the next run puts him back. On the verdict `noeffect`, at most
-- restale_max carriers of the running GiveWater jobs that are members of the detail leave it, again after restale_every.
-- p.rs = {t, ids (released, to be put back), n (rounds)}. Returns the text for the log/cause, or nil
local function detail_member(name, id)
  local found
  pcall(function()
    for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
      if dfhack.df2utf(w.name) == name then
        found = false
        for _, u in ipairs(w.assigned_units) do if u == id then found = true end end
        return
      end
    end
  end)
  return found
end

function M.restale(K, c, r, p, now, gv, sc)
  local rs = type(p.rs) == 'table' and p.rs or nil
  if rs and type(rs.ids) == 'table' and #rs.ids > 0 then            -- last run's carriers go back into the detail
    local back = {}
    for _, id in ipairs(rs.ids) do
      local uid = math.tointeger(id)
      if uid and K.act.work_detail(M.CARER_DETAIL, uid, true, {select = true}) then back[#back + 1] = uid end
    end
    rs.ids = json.array({})
    K.log('info', 'water: %d carrier(s) back in %s after the stale GiveWater job release', #back, M.CARER_DETAIL)
  end
  if not (c.restale and gv and gv.key == 'noeffect' and sc and sc.read ~= false and M.can('work_detail')) then return nil end
  if rs and now - (math.tointeger(rs.t) or -c.restale_every) < c.restale_every then return nil end
  local out = {}
  for _, id in ipairs(sc.w_workers or {}) do
    if #out >= c.restale_max then break end
    if detail_member(M.CARER_DETAIL, id) == true and K.act.work_detail(M.CARER_DETAIL, id, false) then out[#out + 1] = id end
  end
  p.rs = {t = now, ids = json.array(out), n = (rs and math.tointeger(rs.n) or 0) + 1}
  if #out == 0 then
    -- BUG-449: said in the verdict too (the lines are cut at 200: short)
    if #(sc.w_workers or {}) > 0 then gv.unrel = table.concat(sc.w_workers, ',') end
    K.log('warn', 'water: stale GiveWater job (%s) and its carrier(s) %s are no member of %s: nothing to release', gv.reason,
          #(sc.w_workers or {}) > 0 and table.concat(sc.w_workers, ',') or 'unknown', M.CARER_DETAIL)
    return nil
  end
  K.log('warn', 'water: stale GiveWater job (%s): carrier(s) %s taken off %s for one run so the game posts the job anew (round %d)',
        gv.reason, table.concat(out, ','), M.CARER_DETAIL, p.rs.n)
  return string.format('stale job released: carrier %s off %s (round %d)', table.concat(out, ','), M.CARER_DETAIL, p.rs.n)
end

---------------------------------------------------------------- BUG-507/508: stalled water jobs
-- Run 16b i2 Brotherarrow y386: patient 26371 died of thirst in a hospital bed under 'a GiveWater job running 26+ days without
-- effect'; the job hung on a CHILD (26505) who stood 26 days at 81,118,134 beside the dry well 82,119,134, no member of
-- Orderlies (BUG-383 found 'nothing to release'), and the captain (thirst 53,360) hung in FillPond at the same well. The
-- player had no command. A water job (GiveWater, GiveFood, FillPond) is tracked by job id with its worker and his tile
-- (p.sj, at most STALL_TRACK); a worker who has not moved for stall_days game days under the same job is STALLED -- no honest
-- water job keeps a dwarf on one tile for days. It is a case when the worker is over stall_need thirst (or DF's hungry
-- line), or for a Give job when a patient is over thirst_alarm. The kernel never removes a job (DESIGN 5.9, a removed job
-- crashed DF); per stalled worker, at most every stall_every and stall_max workers a run, it takes what the screens give:
--   1. the worker leaves the Orderlies detail for a run (the BUG-383 release, now for every stalled worker; p.rs puts him back),
--   2. a Pond zone within pond_near + 1 tiles of him is removed (the zones screen; the FillPond loop at a dry well),
--   3. from the third round (stall_hosp), the hospital zone a patient over stall_dying lies in is removed (BUG-034's recipe:
--      without the zone the patient fetches his own drink or the carriers bring it).
-- A DECISION_NEEDED job_stalled (A) names the workers and what was done, with the verb `water.unstick unit=<id>` (all
-- steps at once, whatever the age) and inspect what=unit.
M.STALL_JOBS = {'GiveWater', 'GiveWater2', 'GiveFood', 'FillPond'}
M.STALL_TRACK = 60

-- one pass over the job list: [{job, jt, uid, x, y, z, since}] of the tracked jobs that have a worker; nil when this DF
-- knows none of the job types or the list is unreadable
function M.stall_scan(p, now)
  local types = {}
  for _, n in ipairs(M.STALL_JOBS) do
    local v = df.job_type and df.job_type[n]
    if type(v) == 'number' then types[v] = n end
  end
  if next(types) == nil then return nil end
  p.sj = json.object(type(p.sj) == 'table' and p.sj or {})
  local seen, out, n, i = {}, {}, 0, 0
  for _ in pairs(p.sj) do n = n + 1 end
  local ok = pcall(function()
    local link = df.global.world.jobs.list.next
    while link and i < 20000 do
      local j = link.item
      local name = j and types[j.job_type]
      if name and math.type(j.id) == 'integer' then
        local okw, w = pcall(dfhack.job.getWorker, j)
        if okw and w ~= nil then
          local wid = math.type(w) == 'integer' and w or w.id
          local wu = math.type(w) == 'integer' and df.unit.find(w) or w
          local x, y, z
          if wu then x, y, z = dfhack.units.getPosition(wu) end
          local key = fmt(j.id)
          local rec = p.sj[key]
          local same = type(rec) == 'table' and rec.u == wid and rec.x == x and rec.y == y and rec.z == z
          if not same and (type(rec) == 'table' or n < M.STALL_TRACK) then
            if type(rec) ~= 'table' then n = n + 1 end
            rec = {t = now, u = wid, x = x, y = y, z = z, jt = name}
            p.sj[key] = rec
          end
          if type(rec) == 'table' then
            seen[key] = true
            out[#out + 1] = {job = j.id, jt = name, uid = wid, x = x, y = y, z = z, since = rec.t}
          end
        end
      end
      link, i = link.next, i + 1
    end
  end)
  if not ok then return nil end
  for key in pairs(p.sj) do if not seen[key] then p.sj[key] = nil end end      -- done, cancelled or taken over
  return out
end

-- step 3: the hospital zones the patients over stall_dying lie in (at most remove_per_run); returns the zone ids
local function stall_hospital(K, c, r, p, now, need)
  if not c.stall_hosp or not removes(c) then return nil end
  local over, zones, locs, seen, failed = {}, {}, {}, {}, 0
  need = need or c.stall_dying                                -- BUG-541: trap_dying while the carriers stand at a dry well
  for _, pt in ipairs(r.patients) do if pt.thirst >= need then over[#over + 1] = pt end end
  if #over == 0 then return nil end
  table.sort(over, function(a, b) return a.thirst > b.thirst end)
  for _, pt in ipairs(over) do
    for _, h in ipairs(r.hosp) do
      if not seen[h.id] and #zones + failed < c.remove_per_run and M.zone_patients({pt}, h) > 0 then
        seen[h.id] = true
        if K.act.hospital_remove(h.id) then
          M.remember(p, h, now, 'stall')
          zones[#zones + 1] = h.id
          locs[#locs + 1] = h.loc
        else
          failed = failed + 1
        end
      end
    end
  end
  if #zones == 0 then return nil end
  local ids = {}
  for i = 1, math.min(8, #over) do ids[i] = over[i].id end
  K.emit('HOSPITAL_REMOVED', 'A',
         trunc(string.format('removed hospital zone(s) %s: a GiveWater job stalled, patient %d at thirst %d (the zones screen: '
                             .. 'he fetches his own drink or the carriers bring it)', table.concat(zones, ','), over[1].id,
                             over[1].thirst), 200),
         {zones = zones, locs = locs, units = ids, n = #over, thirst = over[1].thirst, patients = #r.patients,
          give = r.give, failed = failed, near = c.near, stalled = 1})
  K.log('warn', 'water: stalled GiveWater job: hospital zone(s) %s removed for patient %d (thirst %d)', table.concat(zones, ','),
        over[1].id, over[1].thirst)
  p.rm = {t = now, zones = zones, locs = locs, n = #over, tmax = over[1].thirst, give = r.give}
  return zones
end

-- BUG-541: the built well with no water below it that a GiveWater worker stands at (within trap_near tiles); nil when none. Only
-- a source that is not wet (an emergency well counts wet; a loop well holds its pond's water, BUG-263): the carriers' bucket cannot fill there
function M.trap_well(c, r, e)
  if c.trap == false or not e.x then return nil end
  local near, best = c.trap_near or 2, nil
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' and s.built ~= false and not s.wet and not s.loop and not s.water and s.x then   -- a loop well holds water (BUG-263)
      local d = math.max(math.abs(s.x - e.x), math.abs(s.y - e.y), math.abs(s.z - e.z))
      if d <= near and (not best or d < best.d) then best = {s = s, d = d} end
    end
  end
  return best and best.s
end

-- the ladder for one stalled worker; returns the list of what was done
local function unstick(K, c, r, p, e)
  local done = {}
  local held = false                                      -- BUG-383's release took him off this very run
  for _, id in ipairs(type(p.rs) == 'table' and type(p.rs.ids) == 'table' and p.rs.ids or {}) do
    if math.tointeger(id) == e.uid then held = true end
  end
  if not held and M.can('work_detail') and detail_member(M.CARER_DETAIL, e.uid) == true
     and K.act.work_detail(M.CARER_DETAIL, e.uid, false) then
    local rs = type(p.rs) == 'table' and p.rs or {n = 0}
    rs.ids = json.array(type(rs.ids) == 'table' and rs.ids or {})
    rs.ids[#rs.ids + 1] = e.uid
    rs.t, rs.n = rs.t or K.now().tick, math.tointeger(rs.n) or 0
    p.rs = rs
    done[#done + 1] = 'off ' .. M.CARER_DETAIL .. ' for a run'
  end
  if e.x and M.can('pond_remove') then
    for _, pd in ipairs(r.ponds or {}) do
      if dist_box(e.x, e.y, e.z, pd) <= (c.pond_near or 3) + 1 and K.act.pond_remove(pd.id) then
        done[#done + 1] = string.format('pond zone %d removed', pd.id)
        break
      end
    end
  end
  return done
end

-- opt: {force = the rules of need, cadence and cap do not apply, unit = only this worker}. Returns
-- {rows = [{uid, jt, days, th, hu, child, x, y, z, did = {text}}], acted = n, hosp = {zones}} or nil
function M.stalls(K, c, r, p, now, opt)
  opt = opt or {}
  if not c.stall and not opt.force then return nil end
  local list = M.stall_scan(p, now)
  p.sa = json.object(type(p.sa) == 'table' and p.sa or {})
  if not list then p.sa = json.object(); return nil end
  local ptop = 0
  for _, pt in ipairs(r.patients) do if pt.thirst > ptop then ptop = pt.thirst end end
  local res, live, acted, deep, trapdeep = {rows = {}, acted = 0}, {}, 0, false, false
  local min_age = c.stall_days * DAY
  for _, e in ipairs(list) do
    live[fmt(e.uid)] = true
    local age = now - e.since
    local u = df.unit.find(e.uid)
    local th, hu, child = 0, 0, false
    pcall(function() th = math.tointeger(u.counters2.thirst_timer) or 0 end)
    pcall(function() hu = math.tointeger(u.counters2.hunger_timer) or 0 end)
    pcall(function() child = not dfhack.units.isAdult(u) end)
    local give = e.jt ~= 'FillPond'
    local case = age >= min_age and (th >= c.stall_need or hu >= M.STARVE_HUNGER or (give and ptop >= c.thirst_alarm))
    if opt.unit ~= nil then case = (opt.unit == e.uid) elseif opt.force then case = age >= min_age end
    -- BUG-541: a GiveWater worker at a dry well is a case after trap_days, whatever his own thirst, once a patient is thirsty
    local well = give and e.jt == 'GiveWater' and M.trap_well(c, r, e) or nil
    if well and age >= (c.trap_days or 1) * DAY and ptop >= c.thirst_watch and (opt.unit == nil or opt.unit == e.uid) then
      case = true
    end
    if case then
      local key = fmt(e.uid)
      local rec = type(p.sa[key]) == 'table' and p.sa[key] or nil
      local row = {uid = e.uid, jt = e.jt, days = age // DAY, th = th, hu = hu, child = child, x = e.x, y = e.y, z = e.z,
                   job = e.job, did = {}, give = give, well = well}
      local due = opt.force or not rec or now - (math.tointeger(rec.t) or -c.stall_every) >= c.stall_every
      if due and (opt.force or acted < c.stall_max) then
        acted = acted + 1
        row.did = unstick(K, c, r, p, e)
        local n = (rec and math.tointeger(rec.n) or 0) + 1
        p.sa[key] = {t = now, n = n}
        row.round = n
        -- BUG-542: the verb (opt.force) never reaches the hospital zone: it cancels the stuck job (off Orderlies) and keeps the zone
        if give and not opt.force then
          if n >= 3 then deep = true end
          if well and n >= 2 then deep, trapdeep = true, true end                  -- BUG-541: the second round is enough at a dry well
        end
      end
      res.rows[#res.rows + 1] = row
    end
  end
  for key in pairs(p.sa) do if not live[key] then p.sa[key] = nil end end       -- his job ended
  res.acted = acted
  if #res.rows == 0 then return res end
  if deep and not opt.force then
    res.hosp = stall_hospital(K, c, r, p, now, trapdeep and math.min(c.stall_dying, c.trap_dying) or nil)
  end
  local parts, ids, cmds = {}, {}, {}
  for _, row in ipairs(res.rows) do
    ids[#ids + 1] = row.uid
    parts[#parts + 1] = string.format('%d%s %s %dd at %s thirst %d%s', row.uid, row.child and ' (child)' or '', row.jt, row.days,
                                      row.x and string.format('%d,%d,%d', row.x, row.y, row.z) or '?', row.th,
                                      #row.did > 0 and (' [' .. table.concat(row.did, ', ') .. ']') or '')
    if #cmds < 3 then cmds[#cmds + 1] = string.format('dfllm cmd water.unstick unit=%d', row.uid) end
  end
  cmds[#cmds + 1] = string.format('dfllm cmd inspect what=unit key=%d', ids[1])
  local q = string.format('%d water job(s) stalled (the worker has not moved): %s', #ids, table.concat(parts, '; '))
  K.log('warn', 'water: %s%s', q, res.hosp and ('; hospital zone(s) ' .. table.concat(res.hosp, ',') .. ' removed') or '')
  local sv = type(p.sv) == 'table' and p.sv or {}
  local key = table.concat(ids, ',')
  -- BUG-541: the carriers that stand at a DRY well get their own decision, early (a patient over thirst_watch, trap_days), with the
  -- command that takes the well away and the nearest accepted water they should fill at
  local tw, twu, twids, seenw = {}, {}, {}, {}
  for _, row in ipairs(res.rows) do
    if row.well then
      twu[#twu + 1] = row.uid
      if not seenw[row.well.id] then seenw[row.well.id] = true; tw[#tw + 1] = row.well; twids[#twids + 1] = row.well.id end
    end
  end
  if #tw > 0 and not opt.force then
    local w1 = tw[1]
    local best
    for _, s in ipairs(r.sources) do
      if s.wet and not s.emerg and s.x then
        local d = dist_box(s.x, s.y, s.z, {x1 = w1.x, y1 = w1.y, x2 = w1.x, y2 = w1.y, z = w1.z})
        if not best or d < best.d then best = {d = d, s = s} end
      end
    end
    local wkey = table.concat(twids, ',')
    local sw = type(p.sw) == 'table' and p.sw or {}
    if sw.key ~= wkey or now - (math.tointeger(sw.t) or -1e12) >= 3 * DAY then
      p.sw = {key = wkey, t = now}
      local wq = string.format('%d GiveWater carrier(s) stand at the DRY well %d (%d,%d,%d, no water below) while a patient is at thirst %d: '
                               .. 'a bucket cannot fill there; nearest accepted water: %s',
                               #twu, w1.id, w1.x, w1.y, w1.z, ptop,
                               best and string.format('%s %d at %d,%d,%d, %d tiles', best.s.kind, best.s.id, best.s.x, best.s.y, best.s.z, best.d)
                               or 'none accepted')
      local wcmds = {}
      for i = 1, math.min(2, #tw) do wcmds[#wcmds + 1] = string.format('dfllm cmd well.retire id=%d', tw[i].id) end
      wcmds[#wcmds + 1] = string.format('dfllm cmd water.unstick unit=%d', twu[1])
      K.emit('DECISION_NEEDED', 'A', trunc('dry_well: ' .. wq, 200),
             {id = 'dry_well', q = trunc(wq, 200), units = twu, cmds = wcmds,
              did = res.rows[1] and #res.rows[1].did > 0 and trunc(table.concat(res.rows[1].did, ', '), 120) or nil})
      K.log('warn', 'water: %s', wq)
    end
  end
  local plain = false
  for _, row in ipairs(res.rows) do if not row.well then plain = true end end
  if plain and not opt.force and (sv.key ~= key or now - (math.tointeger(sv.t) or -1e12) >= 3 * DAY) then
    p.sv = {key = key, t = now}
    K.emit('DECISION_NEEDED', 'A', trunc('job_stalled: ' .. q, 200),
           {id = 'job_stalled', q = trunc(q, 200), units = ids, cmds = cmds, did = res.rows[1] and #res.rows[1].did > 0 and trunc(table.concat(res.rows[1].did, ', '), 120) or nil})
  end
  return res
end

-- verb water.unstick {unit?} (BUG-507): the ladder at once for the stalled water job of ONE worker (a unit that holds a
-- GiveWater, GiveFood or FillPond job and has stood still since the kernel first saw it), or for every stalled worker;
-- the need, cadence and cap rules do not apply, the player's word does
M.verbs['water.unstick'] = function(K, args, cmd)
  local r = st.last
  if not r or not st.out then return false, 'water.unstick: no water run finished yet; try again in a game day' end
  local uid = args.unit ~= nil and math.tointeger(args.unit) or nil
  if args.unit ~= nil and not uid then return false, 'water.unstick: unit must be a unit id' end
  local c, p = M.conf(K), pstate(K)
  local res = M.stalls(K, c, r, p, K.now().tick, {force = true, unit = uid})
  if not res or #res.rows == 0 then
    return false, uid and string.format('water.unstick: unit %d holds no water job the kernel has watched (GiveWater, GiveFood, '
                                        .. 'FillPond)', uid)
                      or 'water.unstick: no stalled water job (no worker stood still for ' .. c.stall_days .. ' days)'
  end
  local out, ids = {}, {}
  for _, row in ipairs(res.rows) do
    ids[#ids + 1] = row.uid
    out[#out + 1] = string.format('%d %s %dd%s', row.uid, row.jt, row.days,
                                  #row.did > 0 and (': ' .. table.concat(row.did, ', ')) or ': nothing to take away')
  end
  -- BUG-542: the verb never removes a hospital zone (Brotherarrow y395: it did, and 'hospital none' followed for 15+ days)
  local msg = 'unstick: ' .. table.concat(out, '; ') .. '; the hospital zone stays'
  K.log('warn', 'water: %s', msg)
  return true, trunc(msg, 400), {n = #res.rows, units = ids}
end

-- verb hospital.restore {loc?} (BUG-539): the hospital zones this module removed (remove_dry, stall_hospital, so water.unstick)
-- drawn again at once at their old location and rectangle; loc = only that location. Any mode (patients lie there).
M.verbs['hospital.restore'] = function(K, args, cmd)
  local loc = args.loc ~= nil and math.tointeger(args.loc) or nil
  if args.loc ~= nil and not loc then return false, 'hospital.restore: loc must be a location id' end
  local c, p = M.conf(K), pstate(K)
  if (type(p.hrm) ~= 'table' or #p.hrm == 0) and #M.orphan_rooms(K, st.last) == 0 then
    return false, 'hospital.restore: no removed hospital zone is remembered and no hospital room stands without a zone (a hospital '
                  .. 'that never lost its zone here: bp sites hospital, or the zones screen)'
  end
  local res = M.restore(K, c, st.last, p, K.now().tick, {force = true, loc = loc})
  if #res.done == 0 then
    return false, 'hospital.restore: ' .. (#res.fail > 0 and table.concat(res.fail, '; ') or 'no remembered zone for that location')
  end
  local msg = string.format('hospital zone(s) %s drawn again%s%s', table.concat(res.done, ','),
                            res.left > 0 and (', ' .. res.left .. ' still remembered') or '',
                            #res.fail > 0 and ('; failed: ' .. table.concat(res.fail, '; ')) or '')
  return true, trunc(msg, 400), {zones = res.done, left = res.left}
end

-- BUG-343 (Guildcleans y389: dead patients with wounds 0 and the thought 'Syndrome'): why a patient lies, as the unit
-- sheet would show it: wounds, the body counters that hold him down (DFHack unit.counters: unconscious, stunned, webbed,
-- suffocation; unit.counters2: paralysis, numbness; scripts/full-heal.lua:112-130 resets the same fields), liquid on his
-- tile (`in water 4/7`: drowning; snapshot.tile's flow and magma), his hunger from M.STARVE_HUNGER (no food reaches
-- him either), the active syndromes' names (at most 2); '' unread
local LIE = {{'counters', 'unconscious'}, {'counters', 'stunned'}, {'counters', 'webbed'}, {'counters', 'suffocation'},
             {'counters2', 'paralysis'}, {'counters2', 'numbness'}}
function M.lie(K, u)
  if not u then return '' end
  local out = {}
  local okw, nw = pcall(function() return #u.body.wounds end)
  if okw and math.tointeger(nw) then out[#out + 1] = 'wounds ' .. nw end
  for _, f in ipairs(LIE) do
    local ok, v = pcall(function() return u[f[1]][f[2]] end)
    if ok and (math.tointeger(v) or 0) > 0 then out[#out + 1] = f[2] end
  end
  pcall(function()
    local okt, t = K.call('snapshot', 'tile', u.pos.x, u.pos.y, u.pos.z)
    local n = okt and type(t) == 'table' and math.tointeger(t.flow) or 0
    if n > 0 then out[#out + 1] = string.format('in %s %d/7', t.magma and 'magma' or 'water', n) end
  end)
  local okh, hu = pcall(function() return math.tointeger(u.counters2.hunger_timer) end)
  if okh and hu and hu >= M.STARVE_HUNGER then out[#out + 1] = 'hunger ' .. hu end
  pcall(function()
    local n = 0
    for _, a in ipairs(u.syndromes.active) do
      if n >= 2 then break end
      local syn = df.syndrome.find(a.type)
      local nm = syn and syn.syn_name
      n = n + 1
      out[#out + 1] = 'syndrome ' .. ((type(nm) == 'string' and nm ~= '') and trunc(nm, 24) or fmt(a.type))
    end
  end)
  return table.concat(out, ', ')
end

---------------------------------------------------------------- BUG-330: water carriers to a patient outside the lockdown
-- Run 15b Earthboat y385 (i3): patient 26629 lay at 74,83,138 outside the alert burrow Tiefe+ (the deep defense) for 30 days
-- of a SIEGE and died of thirst (75,000) while 77 caregivers stood idle in Tiefe+ ('the civ alert holds the caregivers in
-- Tiefe+, the patient lies outside'): a citizen the alert confines takes no job on a tile outside its burrows, nothing let
-- the carriers out, and PATIENTS_OUT only named it. Now, while the civ alert sounds, every patient over care_thirst lying
-- outside every alert burrow (the care burrow itself not counted) with no visible hostile within care_near tiles of him (a
-- fresh census; none read = not safe) gets his tile, the nearest accepted water outside the alert burrows (a wet well's tile,
-- a Water Source zone's rect, at most zone_tiles) and the nearest free bucket outside them, each with no hostile within
-- care_near, painted into the burrow M.CARE (act.burrow_tiles exact: the burrows screen's erase + paint, exactly these
-- tiles), and siege lists that burrow in the alert (siege.alert_list asks water.care_rooms): the caregivers may take the
-- GiveWater job out there. Without accepted water nothing opens (no carrier could bring any; the verdict says so). A hostile
-- within care_near, the patient below care_thirst, dead or inside, or the alert off closes it again (the burrow leaves the
-- list; its tiles are erased and painted anew the next time). kern.log 'water: care burrow ...' on every change.
-- Review fix (merge14): never in BREACH (the BREACH list is Tiefe+ alone: nobody is drawn toward a seal that may be down);
-- outside PEACE/ALERT the patient, water and bucket tiles must lie on Kern+ (unforbid_ok's rule; a well on Kern+ is
-- preferred over a Water Source zone, a zone counts only with every painted tile on Kern+); the painted tiles are kept in
-- st.care and re-checked on every water step and every care_rooms ask (M.care_check): a hostile within care_near of one,
-- a census older than CARE_FRESH, another mode than the one it opened in, or BREACH closes it at once; a census that
-- lists fewer hostiles than it sees (sense keeps the 40 nearest O1) is no distance (foe_dist nil: not safe)
M.CARE = 'Pflege+'
M.CARE_FRESH = 200                     -- ticks a hostile census may be old for the distance check (siege's fresh rule)
M.NOT_YET = 'no thirsty patient outside the alert burrows'
M.ALERT_REPEAT = 4                    -- BUG-596: patient_thirst repeats this much slower while the alert alone keeps the carers away

-- the burrows the sounding civ alert holds the citizens in, the care burrow left out; nil while it is silent
local function alert_set(K)
  local okc, idx = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  if not (okc and idx ~= nil and idx ~= 0) then return nil end
  local okn, names = K.call('siege', 'alert_names')
  names = okn and type(names) == 'table' and names or {}
  local bs = {}
  for _, nm in ipairs(names) do
    if type(nm) == 'string' and nm ~= M.CARE then bs[#bs + 1] = {n = nm, b = burrow_named(nm)} end
  end
  if #bs == 0 then bs = M.alert_burrows(idx, true) end
  return bs
end

local function in_set(bs, x, y, z)
  for _, e in ipairs(bs) do if e.b and on_burrow(e.b, x, y, z) then return true end end
  return false
end

-- the distance of the nearest visible hostile to x,y,z (Chebyshev, z counted); -1 = none in sight; nil = no fresh census
function M.foe_dist(K, x, y, z)
  local h = K.census.h
  if type(h) ~= 'table' or K.now().tick - (math.tointeger(h.tick) or -1000000000) > M.CARE_FRESH then return nil end
  local best = -1
  for _, e in ipairs(type(h.list) == 'table' and h.list or {}) do
    if e.x then
      local d = math.max(math.abs(e.x - x), math.abs(e.y - y), math.abs(e.z - z))
      if best < 0 or d < best then best = d end
    end
  end
  -- in sight but not listed (BUG-330 review: sense lists only the LIST_MAX nearest O1): unknown, never 'far'.
  -- BUG-596 (Run 16b i2 Brotherarrow y406-y414: 57 hostiles in sight for 100+ days, 40 listed, 'Pflege+ not opened: no fresh hostile census'
  -- for 14 DECISIONs, 2 patients dead of thirst): the unlisted ones lie at least h.lo tiles from O1 (sense: the last listed one's distance),
  -- so by the triangle inequality at least lo - d(tile, O1) from the tile; that bound (when it is positive) stands in for them
  if (math.tointeger(h.vis) or 0) > #(type(h.list) == 'table' and h.list or {}) then
    local lo, o1 = math.tointeger(h.lo), type(h.o1) == 'table' and h.o1 or nil
    local ox, oy, oz = o1 and math.tointeger(o1[1]), o1 and math.tointeger(o1[2]), o1 and math.tointeger(o1[3])
    if not (lo and ox and oy and oz) then return nil end
    local lb = lo - math.max(math.abs(ox - x), math.abs(oy - y), math.abs(oz - z))
    if lb <= 0 then return nil end
    if best < 0 or lb < best then best = lb end
  end
  return best
end

-- BUG-559: the distance a hostile must keep from a care tile: care_near, in BREACH (a hostile is on Kern+) care_breach_near
local function near_for(c, mode)
  if mode == 'BREACH' then return math.max(c.care_near, math.tointeger(c.care_breach_near) or 0) end
  return c.care_near
end

-- BUG-571: may the SIEGE care burrow reach outside Kern+: the fort is sealed (seal's entrance check, fresh) and care_siege_out
local function care_ext(K, c, mode)
  if mode ~= 'SIEGE' or c.care_siege_out == false then return false end
  local ok, G = K.call('seal', 'groups')
  return ok and type(G) == 'table' and not G.stale and G.sealed == true
end

-- BUG-571: a tile outside Kern+ that the SIEGE care burrow may use: on the citizens' walk groups (inside the walls)
local function care_out_ok(K, ext, x, y, z)
  if not ext then return false end
  local ok, far = K.call('snapshot', 'far', x, y, z)
  return ok and far == false
end

local function care_safe(K, c, x, y, z, near)
  local d = M.foe_dist(K, x, y, z)
  if d == nil then return false, 'no fresh hostile census' end
  if d >= 0 and d <= (near or c.care_near) then return false, string.format('a hostile %d tiles from it', d) end
  return true
end

local function cheb(a, x, y, z) return math.max(math.abs(x - a[1]), math.abs(y - a[2]), math.abs(z - a[3])) end

-- one run's decision: st.care = {on, ids = {[id] = true}, sig, n, why, t}; paints only on a change of the tile set
function M.care_step(K, c, r, now)
  local prev = st.care
  local function close(why)
    if prev and prev.on then K.log('info', 'water: care burrow %s closed: %s', M.CARE, why) end
    st.care = {on = false, ids = {}, why = why, t = now, th = c.care_thirst}
    return st.care
  end
  if not c.care or not M.can('burrow_tiles') then st.care = nil; return nil end
  local bs = alert_set(K)
  if not bs then return close('the civ alert is off') end
  -- review fix: outside PEACE/ALERT only tiles on Kern+ (unforbid_ok's rule); BUG-559: BREACH only with care_breach, on Kern+
  -- and with every hostile care_breach_near tiles off (before: never, 3 patients on Kern+ died of thirst in the y402 BREACH)
  local mode = K.mode()
  if mode == 'BREACH' and not c.care_breach then return close('BREACH: nobody is drawn out toward a seal that may be down') end
  local near = near_for(c, mode)
  local strict = mode ~= 'PEACE' and mode ~= 'ALERT'
  local kern, kname = burrow(K, 'kern', 'Kern+')
  if strict and not kern then return close(string.format('%s: no %s burrow to keep it inside', mode, kname)) end
  local ext = strict and care_ext(K, c, mode)                -- BUG-571
  local far_near = math.max(near, math.tointeger(c.care_siege_near) or 0)
  local function inside(x, y, z) return not strict or on_burrow(kern, x, y, z) or care_out_ok(K, ext, x, y, z) end
  -- BUG-571: a tile outside Kern+ keeps the wider distance from every hostile
  local function dist_for(x, y, z) return (strict and not on_burrow(kern, x, y, z)) and far_near or near end
  local out = {}
  for _, pt in ipairs(r.patients) do
    if pt.x and pt.thirst >= c.care_thirst and not in_set(bs, pt.x, pt.y, pt.z) then out[#out + 1] = pt end
  end
  if #out == 0 then return close(M.NOT_YET) end
  local tiles, ids, sig, why = {}, {}, {}, nil
  local function add(x, y, z) tiles[#tiles + 1] = {x, y, z}; sig[#sig + 1] = string.format('%d,%d,%d', x, y, z) end
  for _, pt in ipairs(out) do
    local ok, w = care_safe(K, c, pt.x, pt.y, pt.z, dist_for(pt.x, pt.y, pt.z))
    if ok and not inside(pt.x, pt.y, pt.z) then ok, w = false, string.format('outside %s in %s', kname, mode) end
    if ok then ids[pt.id] = true; add(pt.x, pt.y, pt.z) else why = why or string.format('patient %d: %s', pt.id, w) end
  end
  if #tiles == 0 then return close(why or 'no patient safe to reach') end
  local ref = tiles[1]
  -- the water: none wet = nothing to carry (the verdict names it); one inside the alert burrows needs no tile
  -- the tiles a source paints (a zone's rect, at most zone_tiles; a well's tile)
  local function src_tiles(s)
    local b, l = s.box, {}
    if not b then return {{s.x, s.y, s.z}} end
    for y = b.y1, b.y2 do
      for x = b.x1, b.x2 do
        if #l < c.zone_tiles then l[#l + 1] = {x, y, b.z} end
      end
    end
    return l
  end
  local wet, near_w, nd, nr = false, nil, nil, nil
  for _, s in ipairs(r.sources) do
    if s.wet then
      wet = true
      if in_set(bs, s.x, s.y, s.z) then near_w = 'in'; break end
      local ok, kin = care_safe(K, c, s.x, s.y, s.z, dist_for(s.x, s.y, s.z)), true
      for _, t in ipairs(src_tiles(s)) do
        if not on_burrow(kern, t[1], t[2], t[3]) then kin = false end
        if not inside(t[1], t[2], t[3]) then ok = false end
        if ok and not care_safe(K, c, t[1], t[2], t[3], dist_for(t[1], t[2], t[3])) then ok = false end    -- BUG-571
      end
      -- review fix: a well on Kern+ first, then the nearest (a Water Source zone may lie outside the walls)
      local rank, d = (s.kind ~= 'zone' and kin) and 0 or 1, cheb(ref, s.x, s.y, s.z)
      if ok and (not nd or rank < nr or (rank == nr and d < nd)) then near_w, nd, nr = s, d, rank end
    end
  end
  if not wet then return close('no accepted water (nothing to carry)') end
  if not near_w then
    return close(strict and string.format('every accepted water outside the alert burrows has a hostile near it or ' ..
                                          'lies outside %s%s', kname,
                                          (mode == 'SIEGE' and not ext and c.care_siege_out ~= false)
                                          and ' (outside it only with the walls verified sealed, BUG-571)' or '')
                 or 'every accepted water outside the alert burrows has a hostile near it')
  end
  if near_w ~= 'in' then
    for _, t in ipairs(src_tiles(near_w)) do add(t[1], t[2], t[3]) end
  end
  -- a free bucket the confined carriers may take (one inside the alert burrows needs none)
  local bk, bd, bin = nil, nil, false
  for _, q in ipairs(r.bpos or {}) do
    if in_set(bs, q.x, q.y, q.z) then bin = true; break end
    local d = cheb(ref, q.x, q.y, q.z)
    if inside(q.x, q.y, q.z) and care_safe(K, c, q.x, q.y, q.z, dist_for(q.x, q.y, q.z)) and (not bd or d < bd) then bk, bd = q, d end
  end
  if bk and not bin then add(bk.x, bk.y, bk.z) end
  local s = table.concat(sig, ' ')
  local cs = {on = true, ids = ids, sig = s, t = now, n = #tiles, th = c.care_thirst,
              tiles = tiles, mode = mode, ext = ext == true}  -- review fix: care_check re-checks these tiles
  if not (prev and prev.on and prev.sig == s) then
    local ok, res = K.act.burrow_tiles(M.CARE, tiles, true, true)
    if not ok then return close('act.burrow_tiles: ' .. trunc(tostring(res), 60)) end
    local pid = {}
    for id in pairs(ids) do pid[#pid + 1] = id end
    table.sort(pid)
    K.log('warn', 'water: care burrow %s opened to patient(s) %s outside the alert burrow %s: %d tiles (%s)', M.CARE,
          table.concat(pid, ','), bs[1] and bs[1].n or '?', #tiles, trunc(s, 120))
  else cs.t = prev.t end
  st.care = cs
  return cs
end

-- BUG-330 review fix: the open care burrow against the current census and mode, between the water runs (care_step runs
-- once a run, 1200+ ticks apart): BREACH, another mode than the one it opened in, a census older than CARE_FRESH or a
-- hostile within care_near of one of its painted tiles (or one not listed) closes it at once; true while it stays open
function M.care_check(K)
  local cs = st and st.care
  if not (cs and cs.on) then return false end
  local now, mode = K.now().tick, K.mode()
  local c = M.conf(K)
  local why
  if mode == 'BREACH' and not c.care_breach then why = 'BREACH: nobody is drawn out toward a seal that may be down'
  elseif cs.mode and mode ~= cs.mode and not (FIGHT[mode] and FIGHT[cs.mode]) then
    why = string.format('the mode changed (%s -> %s)', cs.mode, mode)
  else
    -- BUG-559: SIEGE <-> BREACH keeps it (both paint Kern+ tiles only), checked against the new mode's distance
    -- BUG-571: a tile outside Kern+ (care_siege_out) keeps the wider care_siege_near, and the walls must still be verified sealed
    local kern = cs.ext and burrow(K, 'kern', 'Kern+') or nil
    if cs.ext and not care_ext(K, c, mode) then why = 'the walls are not verified sealed any more (outside Kern+ needs a SIEGE with sealed walls)' end
    for _, t in ipairs(why and {} or cs.tiles or {}) do
      local near = near_for(c, mode)
      if cs.ext and not on_burrow(kern, t[1], t[2], t[3]) then near = math.max(near, math.tointeger(c.care_siege_near) or 0) end
      local ok, w = care_safe(K, c, t[1], t[2], t[3], near)
      if not ok then why = string.format('%d,%d,%d: %s', t[1], t[2], t[3], w); break end
    end
    if not why then cs.mode = mode end
  end
  if not why then return true end
  K.log('info', 'water: care burrow %s closed: %s', M.CARE, why)
  st.care = {on = false, ids = {}, why = why, t = now, th = cs.th}
  return false
end

-- public (BUG-330, siege.alert_list): the burrows water wants in the civ alert's list now: {M.CARE} while it is open
-- (review fix: re-checked on every ask, M.care_check)
function M.care_rooms(K)
  if M.care_check(K) then return {M.CARE} end
  return {}
end

-- the plan of one run: {have, want, idle, added = {ids}, dropped = {ids}, err}. `over` = a patient is over thirst_alarm.
-- Adds through act.work_detail (water must be an owner of it: feature detection) and only the kernel's own additions
-- (p.cw: id -> tick) ever leave again
function M.carers(K, c, r, p, now, over)
  p.cw = json.object(type(p.cw) == 'table' and p.cw or {})
  local np, have = #r.patients, #r.carers
  local want = 0
  if np > 0 and c.carers_max > 0 then
    want = math.max(c.carers_min, np * c.carers_per_patient)
    if over then want = want + c.carers_urgent end
    want = math.min(want, c.carers_max)
  end
  local out = {have = have, want = want, idle = r.carers_idle, added = {}, dropped = {}}
  if np > 0 then p.cw_t = now end
  local mine = 0
  for sid in pairs(p.cw) do                                       -- a unit that died or left is forgotten
    local u = df.unit.find(math.tointeger(tonumber(sid)) or -1)
    if not u or dfhack.units.isDead(u) then p.cw[sid] = nil else mine = mine + 1 end
  end
  out.mine = mine
  if not M.can('work_detail') then out.err = 'water may not change work details'; return out end
  if have < want and mine >= c.carers_max then
    -- the kernel already put carers_max citizens into the detail and they are not caregivers: its labors do not grant
    -- FEED_WATER_CIVILIANS (or the game took them off); more members would change nothing
    out.err = string.format('%d citizens added to %s hold no FEED_WATER_CIVILIANS labor', mine, M.CARER_DETAIL)
  elseif have < want and now >= (math.tointeger(p.cw_off) or 0) then
    local ref = r.hosp[1] or (r.patients[1] and {x1 = r.patients[1].x or 0, y1 = r.patients[1].y or 0,
                                                 x2 = r.patients[1].x or 0, y2 = r.patients[1].y or 0,
                                                 z = r.patients[1].z or 0})
    local pool = {}
    for _, cd in ipairs(r.pool) do pool[#pool + 1] = {cd = cd, d = ref and dist_box(cd.x, cd.y, cd.z, ref) or 0} end
    table.sort(pool, function(a, b)
      if a.cd.idle ~= b.cd.idle then return a.cd.idle end
      if a.d ~= b.d then return a.d < b.d end
      return a.cd.id < b.cd.id
    end)
    for _, e in ipairs(pool) do
      if #out.added >= c.carers_per_run or have + #out.added >= want or mine + #out.added >= c.carers_max then break end
      local cu = df.unit.find(e.cd.id)
      if cu and not p.cw[fmt(e.cd.id)] and M.carer_ok(cu) then      -- (one of ours without the labor: the next one)
        local ok, res = K.act.work_detail(M.CARER_DETAIL, e.cd.id, true, {select = true})
        if ok then
          out.added[#out.added + 1] = e.cd.id
          p.cw[fmt(e.cd.id)] = now
        else
          out.err = tostring(res)
          if out.err:find('no work detail', 1, true) then p.cw_off = now + NO_WAIT end
          break                                                  -- an ACT_FAIL (B) names it; the next run tries again
        end
      end
    end
  elseif np == 0 and next(p.cw) and now - (math.tointeger(p.cw_t) or now) >= c.carers_hold_days * DAY then
    local sids = {}
    for sid in pairs(p.cw) do sids[#sids + 1] = sid end
    table.sort(sids)
    local id = math.tointeger(tonumber(sids[1]))
    if id and K.act.work_detail(M.CARER_DETAIL, id, false) then out.dropped[1] = id end
    p.cw[sids[1]] = nil                                          -- gone either way (a refusal: the player's member now)
  end
  out.have_after = have + #out.added
  return out
end

---------------------------------------------------------------- BUG-106: the hospital audit
-- Run 14 (post-mortem: 52 bled out, 87 suffocated, mostly patients; note 90): care gives DIAGNOSE, SURGERY and BONE_SETTING
-- and nothing else of wound care; no tool listed what a hospital lacks. `inspect what=hospital` (and the gaps in the state's
-- water.gaps) lists, in a fixed vocabulary, what a player sees in the hospital zone and on the labors screen: the zone
-- inside the refuge, accepted water, beds, a table, a traction bench, doctors with the five wound care labors (and skills),
-- the supplies the hospital location asks for and holds (splints, thread, cloth, crutches, plaster, soap, buckets), the
-- caregivers. Read only, once per water run (a game day); never writes. Which of these the game's treatment really needs
-- is not decided offline (bugs/BUG-106).
M.GAPS_MAX = 16
M.MEDIC = {{'diag', {'DIAGNOSE'}, {'DIAGNOSE'}}, {'surg', {'SURGERY'}, {'SURGERY'}},
           {'bone', {'BONE_SETTING'}, {'SET_BONE'}}, {'suture', {'SUTURING', 'SUTURE'}, {'SUTURE'}},
           {'dress', {'DRESSING_WOUNDS', 'DRESS_WOUNDS'}, {'DRESS_WOUNDS', 'DRESSING_WOUNDS'}}}
-- BUG-153 (live i4): the labor names of df.unit_labor in DF 53.16 (18 DIAGNOSE .. 21 SUTURING, 22 DRESSING_WOUNDS); the
-- skills (df.job_skill) are SET_BONE, SUTURE, DRESS_WOUNDS
M.MEDIC_LABOR = {diag = 'DIAGNOSE', surg = 'SURGERY', bone = 'BONE_SETTING', suture = 'SUTURING', dress = 'DRESSING_WOUNDS'}
M.SUPPLY = {{'splints', {'splints'}}, {'thread', {'thread'}}, {'cloth', {'cloth'}}, {'crutches', {'crutches'}},
            {'plaster', {'powder', 'plaster'}}, {'soap', {'soap'}}, {'buckets', {'buckets'}}}

local function enum_val(enum, names)
  for _, n in ipairs(names) do
    local v = enum and enum[n]
    if type(v) == 'number' then return v end
  end
end

-- who holds the wound care labors (r.doc[kind] = {on = holders, skilled = with a skill above 0, nil unknown}); called for
-- every citizen of phase_units that is no patient: adults outside the squads
function M.medic_count(r, u)
  local ok = pcall(function()
    if not dfhack.units.isAdult(u) or (u.military.squad_id or -1) >= 0 then return end
    for _, m in ipairs(M.MEDIC) do
      local lab = enum_val(df.unit_labor, m[2])
      if lab and u.status.labors[lab] == true then
        local e = r.doc[m[1]] or {on = 0, skilled = 0}
        r.doc[m[1]] = e
        e.on = e.on + 1
        local sk = enum_val(df.job_skill, m[3])
        local okk, lv = false, nil
        if sk and dfhack.units.getNominalSkill then okk, lv = pcall(dfhack.units.getNominalSkill, u, sk) end
        if okk and math.type(lv) == 'integer' then
          if lv > 0 then e.skilled = (e.skilled or 0) + 1 end
        else
          e.skilled = nil
        end
      end
    end
  end)
  return ok
end

local function field(o, ...)
  local path = {...}
  local ok, v = pcall(function()
    local x = o
    for _, k in ipairs(path) do x = x[k] end
    return x
  end)
  if ok and (type(v) == 'number' or type(v) == 'boolean') then return v end
end

-- what the hospital location asks for and holds of one supply: want (desired_<f>), have (count_<f>), need (need_more.<f>)
local function supply_of(loc, names)
  local want, have, need
  for _, f in ipairs(names) do
    want = want or field(loc, 'contents', 'desired_' .. f)
    have = have or field(loc, 'contents', 'count_' .. f)
    need = need == nil and field(loc, 'contents', 'need_more', f) or need
  end
  return math.tointeger(want), math.tointeger(have), need
end

-- furniture inside the hospital zones: what stands on the tiles of each zone (dfhack.buildings.findAtTile, a linear scan: at most
-- M.AUDIT_TILES tiles per zone, an even sample of a bigger one, `capped` then); each building counted once
M.AUDIT_TILES = 200
local function zone_furniture(zones)
  local bt = df.building_type
  local want = {bed = bt and bt.Bed, table = bt and bt.Table, bench = bt and bt.TractionBench}
  local out = {}
  for i = 1, #zones do out[i] = {bed = 0, table = 0, bench = 0} end
  if want.bed == nil or want.table == nil or want.bench == nil or not dfhack.buildings.findAtTile then return out, false end
  for i, h in ipairs(zones) do
    local area, step = (h.x2 - h.x1 + 1) * (h.y2 - h.y1 + 1), 1
    while area > M.AUDIT_TILES * step * step do step = step + 1 end
    out[i].capped = step > 1 or nil
    local seen = {}
    for y = h.y1, h.y2, step do
      for x = h.x1, h.x2, step do
        local ok, b = pcall(dfhack.buildings.findAtTile, x, y, h.z)
        if ok and b and not seen[b.id] then
          seen[b.id] = true
          local okt, ty = pcall(function() return b:getType() end)
          local kind = okt and ((ty == want.bed and 'bed') or (ty == want.table and 'table')
                                or (ty == want.bench and 'bench')) or nil
          if kind then out[i][kind] = out[i][kind] + 1 end
        end
      end
    end
  end
  return out, true
end

local function gap(list, tok, txt)
  if #list < M.GAPS_MAX then list[#list + 1] = {tok = tok, txt = trunc(txt, 70)} end
end

-- ctx: {dry, best (nearest accepted water {d}), ho (hospital_out), after (caregivers), idle}
function M.audit(K, c, r, ctx)
  local a = {tick = K.now().tick, patients = #r.patients, zones = #r.hosp, gaps = {}, sup = {}, doc = {}}
  local gaps = a.gaps
  local zl = {}
  for i = 1, math.min(6, #r.hosp) do zl[i] = r.hosp[i] end
  local fur, fur_ok = zone_furniture(zl)
  a.rooms = {}
  local beds, tables, benches = 0, 0, 0
  for i, h in ipairs(zl) do
    a.rooms[i] = {id = h.id, box = {h.x1, h.y1, h.z, h.x2, h.y2}, beds = fur[i].bed, tables = fur[i].table,
                  bench = fur[i].bench, capped = fur[i].capped}
    beds, tables, benches = beds + fur[i].bed, tables + fur[i].table, benches + fur[i].bench
  end
  if #r.hosp == 0 then
    gap(gaps, 'no_zone', 'no hospital zone with a location')
  else
    local ho = ctx.ho
    if ho and ho.n > 0 then
      local tiles, of = 0, 0
      for _, z in ipairs(ho.zones) do tiles, of = tiles + z.tiles, of + z.of end
      gap(gaps, 'outside', string.format('%d of %d zone tiles outside %s/%s', tiles, of, ho.kern, ho.refuge))
    end
    if ctx.dry then
      gap(gaps, 'dry', ctx.best and string.format('nearest accepted water %d tiles away', ctx.best.d)
                       or 'no accepted water in the fort')
    end
    if fur_ok then
      if beds < math.max(1, #r.patients) then
        gap(gaps, 'no_bed', string.format('%d beds in the zone for %d patients', beds, #r.patients))
      end
      if tables == 0 then gap(gaps, 'no_table', 'no table in the zone (surgery, suturing)') end
      if benches == 0 then gap(gaps, 'no_traction', 'no traction bench in the zone (bone setting)') end
    end
  end
  -- doctors: citizens outside the squads with each labor on
  local order = {diag = 'no_diag', surg = 'no_surgery', bone = 'no_bone', suture = 'no_suture', dress = 'no_dress'}
  for _, m in ipairs(M.MEDIC) do
    local e = r.doc[m[1]]
    a.doc[m[1]] = e and {on = e.on, skilled = e.skilled} or {on = 0}
    local lab = M.MEDIC_LABOR[m[1]]
    if not e or e.on == 0 then
      gap(gaps, order[m[1]], 'no adult citizen has the ' .. lab .. ' labor on')
    elseif e.skilled == 0 then
      gap(gaps, order[m[1]], string.format('%d have the %s labor on, none has the skill', e.on, lab))
    end
  end
  -- supplies the hospital location asks for and holds
  local locs = hospital_locations()
  local loc = r.hosp[1] and locs[r.hosp[1].loc]
  local known = false
  if loc then
    local ci = K.census.i
    for _, sp in ipairs(M.SUPPLY) do
      local want, have, need = supply_of(loc, sp[2])
      local fort = type(ci) == 'table' and (sp[1] == 'thread' or sp[1] == 'cloth') and math.tointeger(ci[sp[1]]) or nil
      a.sup[sp[1]] = {want = want, have = have, need = need, fort = fort}
      if want ~= nil or have ~= nil or need ~= nil then known = true end
      if want == 0 then
        gap(gaps, 'no_' .. sp[1], 'the location asks for 0: nobody brings any' .. (fort and (', fort ' .. fort) or ''))
      elseif (have ~= nil and want ~= nil and have < want) or (have == nil and need == true) then
        gap(gaps, 'no_' .. sp[1], string.format('asks %s, holds %s%s', want and tostring(want) or '?',
                                                have and tostring(have) or '?', fort and (', fort ' .. fort) or ''))
      end
    end
    if not known then gap(gaps, 'supply_unknown', 'the location has no supply fields to read') end
  end
  -- caregivers
  a.carers = {have = ctx.after, idle = ctx.idle}
  if #r.patients > 0 or #r.hosp > 0 then
    if (ctx.after or 0) == 0 then gap(gaps, 'no_carers', 'no caregiver with FEED_WATER_CIVILIANS') end
  end
  a.outsiders = r.outsiders
  return a
end

---------------------------------------------------------------- BUG-537: the hospital's missing furniture and supplies
-- Run 16c i3 Sealcertain / i2: a hospital with patients and no table, no splints, no thread or cloth (the audit listed them, nobody was
-- asked). A hospital with a patient in it and one of the gaps below raises DECISION_NEEDED hospital_supply (A) with the commands
-- that make or buy what is missing (a table is the bp template's now: `hospital` places one); once per hosp_sup_every and again when
-- the set of gaps changes (util/cadence).
M.SUPPLY_FIX = {
  no_table = {'a table in the zone (the hospital template places one; build it in the zone otherwise)', nil},
  no_traction = {'a traction bench in the zone (bone setting)', nil},
  no_splints = {'splints', 'dfllm cmd order.add \'{"job":"ConstructSplint","amount":4}\''},
  no_thread = {'thread', 'dfllm cmd trade.want \'{"add":["thread"]}\''},
  no_cloth = {'cloth', 'dfllm cmd trade.want \'{"add":["cloth"]}\''},
}
M.SUPPLY_ORDER = {'no_table', 'no_traction', 'no_splints', 'no_thread', 'no_cloth'}
function M.supply_ask(K, c, p, a)
  local have = {}
  for _, g in ipairs(a.gaps or {}) do have[g.tok] = true end
  local toks, names, cmds = {}, {}, {}
  if (a.patients or 0) > 0 and (a.zones or 0) > 0 then
    for _, tk in ipairs(M.SUPPLY_ORDER) do
      if have[tk] then
        local e = M.SUPPLY_FIX[tk]
        toks[#toks + 1] = tk
        names[#names + 1] = e[1]
        if e[2] then cmds[#cmds + 1] = e[2] end
      end
    end
  end
  if #toks == 0 then
    p.hsup = CAD.quiet(p.hsup)
    return
  end
  local T = K.now()
  if not CAD.due(p.hsup, T, {}, toks, {ticks = c.hosp_sup_every, wall_s = c.wake_wall_s}) then return end
  p.hsup = CAD.mark(T, {}, toks)
  local q = trunc(string.format('hospital with %d patient(s) lacks %s', a.patients, table.concat(names, '; ')), 200)
  K.emit('DECISION_NEEDED', 'A', trunc('hospital_supply: ' .. q, 200),
         {id = 'hospital_supply', q = q, gaps = {table.unpack(toks)}, cmds = #cmds > 0 and cmds or nil})
end

---------------------------------------------------------------- BUG-131: stale hospital zones outside the core
-- Run 14 (site90): R0 hospital_out stayed red the whole run over an old zone (24422 at 88,28, "1 of 3 zones") while a
-- hospital inside the core stood or was being built; the playbook forbids the session to delete zones, so goal G3 never
-- turned green. A zone outside Kern+/Tiefe+ does not block (state water.hosp_out) when it is idle (no patient lies in it,
-- no bed stands in it and its location holds no supply, all three known) or superseded (a finished hospital, a zone
-- wholly inside with a bed, exists and no patient lies in it). Unknown furniture or supplies count as present: the zone
-- blocks. ho.ign lists the ignored ones with `why`, ho.fin is the finished hospital inside, ho.raw all zones outside.
M.SORT_ZONES = 12          -- hospital zones whose furniture is read per run (the rest are unknown: they block)

function M.zone_patients(pts, h)
  local n = 0
  for _, pt in ipairs(pts) do
    if pt.x and pt.z == h.z and pt.x >= h.x1 and pt.x <= h.x2 and pt.y >= h.y1 and pt.y <= h.y2 then n = n + 1 end
  end
  return n
end

-- the supplies a hospital location holds (its count_* fields summed), nil when it shows none of them
function M.loc_supply(loc)
  if not loc then return nil end
  local sum, known = 0, false
  for _, sp in ipairs(M.SUPPLY) do
    local _, have = supply_of(loc, sp[2])
    if have ~= nil then known, sum = true, sum + have end
  end
  return known and sum or nil
end

function M.hosp_sort(K, r, ho)
  ho.raw, ho.ign = ho.n, {}
  if ho.n == 0 then return ho end
  local zl, rect, out_ids, beds = {}, {}, {}, {}
  for i, h in ipairs(r.hosp) do
    rect[h.id] = h
    if i <= M.SORT_ZONES then zl[i] = h end
  end
  for _, z in ipairs(ho.zones) do out_ids[z.id] = true end
  local fur, fur_ok = zone_furniture(zl)
  for i, h in ipairs(zl) do
    if fur_ok then beds[h.id] = fur[i].bed end
    if fur_ok and not out_ids[h.id] and fur[i].bed > 0 and not ho.fin then ho.fin = h.id end
  end
  local locs = hospital_locations()
  local keep = {}
  for _, z in ipairs(ho.zones) do
    z.pat, z.beds, z.sup = M.zone_patients(r.patients, rect[z.id]), beds[z.id], M.loc_supply(locs[z.loc])
    local why
    if z.pat == 0 and z.beds == 0 and z.sup == 0 then why = 'idle'
    elseif z.pat == 0 and ho.fin then why = 'superseded' end
    if why then z.why = why; ho.ign[#ho.ign + 1] = z else keep[#keep + 1] = z end
  end
  ho.zones, ho.n = keep, #keep
  if #ho.ign ~= (st.ign_n or 0) then
    st.ign_n = #ho.ign
    if #ho.ign > 0 then
      local z = ho.ign[1]
      K.log('info', 'water: %d hospital zone(s) outside %s/%s do not block (BUG-131): zone %d at %d,%d,%d %s; '
            .. 'hospital.retire removes it', #ho.ign, ho.kern, ho.refuge, z.id, z.x, z.y, z.z, z.why)
    end
  end
  return ho
end

---------------------------------------------------------------- BUG-264: a well that waits for its chain or rope
-- Run 15 Earthboat y372-y375: the hospital's well 49,90,135 stood at 47 % for a year, "job 6483 suspended by buildingplan:
-- waits for chain x1": 0 bars, 0 cloth, 244 thread, quickfort's "Make cloth rope" order waited for a Clothier's shop and
-- cloth no Loom wove; nobody asked for either. Now, per run, a well under construction whose job wants a chain (item type
-- CHAIN: a metal chain or a cloth rope) none is attached for gets a route, at most every CHAIN_EVERY for its acts:
--   metal  free bars of a hard metal (ITEMS_HARD) and a Metalsmith's forge: a MakeChain order of that metal (dfllm:chain);
--   cloth  free cloth: a MakeChain order of cloth (a rope) at the Clothier's shop, or PROJECT_REQUEST workshops why=well
--          types [Clothiers] without one;
--   thread thread but no cloth: PROJECT_REQUEST workshops why=well for the Loom (economy's cloth floor weaves) and Clothiers;
--   forge  hard-metal bars but no forge (and no cloth or thread): PROJECT_REQUEST workshops why=well [MetalsmithsForge];
--   trade  none of it: buy rope or a chain (the text says trade.want chain; the kernel adds no want).
-- A live MakeChain order (anyone's) is never doubled. The route is in HOSPITAL_DRY's cause, kern.log and inspect
-- water_sources (chain). Reads the well's job (job_items, attached items), bars, manager orders, workshop types.
M.CHAIN_EVERY = 14 * DAY

function M.chain_wait(w)
  local ok, yes = pcall(function()
    local CH = df.item_type and df.item_type.CHAIN
    local j = CH ~= nil and w.jobs and w.jobs[0]
    if not j then return false end
    local att = {}
    for _, ref in ipairs(j.items) do
      local idx = math.tointeger(ref.job_item_idx)
      if idx then att[idx] = (att[idx] or 0) + 1 end
    end
    for i, ji in ipairs(j.job_items.elements or j.job_items) do      -- DF 50+: a struct holding the vector
      if ji.item_type == CH and (math.tointeger(ji.quantity) or 1) > (att[i] or 0) then return true end
    end
    return false
  end)
  return ok and yes == true
end

-- the workshop types standing (buildings.other.WORKSHOP_ANY, the type the building sheet shows): name -> true
function M.shops()
  local out = {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local okt, t = pcall(function() return b:getSubtype() end)
      local name = okt and df.workshop_type[t]
      if type(name) == 'string' then out[name] = true end
    end
  end)
  return out
end

-- the hard metal (ITEMS_HARD: a forge makes chains of it) with the most free bars: token, count (nil, 0 without)
function M.chain_metal()
  local by, best, bn = {}, nil, 0
  pcall(function()
    for _, it in ipairs(df.global.world.items.other.BAR) do
      local f = it.flags
      if not (f.forbid or f.in_job or f.removed or f.garbage_collect or f.trader) then
        local mi = dfhack.matinfo.decode(it)
        local fl = mi and mi.material and mi.material.flags
        if fl and fl.IS_METAL and fl.ITEMS_HARD then
          local tok = mi:getToken()
          by[tok] = (by[tok] or 0) + 1
          if by[tok] > bn then best, bn = tok, by[tok] end
        end
      end
    end
  end)
  return best, bn
end

-- a live MakeChain manager order (anyone's: quickfort's "Make cloth rope" too): its id or nil
function M.chain_order()
  local id
  pcall(function()
    local jt = df.job_type.MakeChain
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if jt ~= nil and o.job_type == jt and (o.amount_left or 0) > 0 then id = o.id; return end
    end
  end)
  return id
end

function M.chain(K, c, r, p, now)
  local wells = {}
  for _, s in ipairs(r.sources) do if s.kind == 'well' and s.chain then wells[#wells + 1] = s end end
  if #wells == 0 then st.chain, p.chain_t = nil, nil; return nil end
  local ci = type(K.census.i) == 'table' and K.census.i or {}
  local cloth, thread = math.tointeger(ci.cloth) or 0, math.tointeger(ci.thread) or 0
  local shops = M.shops()
  local tok, bars = M.chain_metal()
  local route, need, spec = 'trade', {}, nil
  if tok and shops.MetalsmithsForge then
    route, spec = 'metal', {job = 'MakeChain', material = tok}
  elseif cloth > 0 then
    route = 'cloth'
    if shops.Clothiers then spec = {job = 'MakeChain', material_category = {'cloth'}} else need = {'Clothiers'} end
  elseif thread > 0 then
    route = 'thread'
    for _, t in ipairs({'Loom', 'Clothiers'}) do if not shops[t] then need[#need + 1] = t end end
  elseif tok then
    route, need = 'forge', {'MetalsmithsForge'}
  end
  local due = now - (math.tointeger(p.chain_t) or -M.CHAIN_EVERY) >= M.CHAIN_EVERY
  local live = M.chain_order()
  local done = live and 'on order' or nil
  if due and spec and not live and M.can('workorder') then
    spec.tag, spec.amount_total, spec.frequency = 'dfllm:chain', #wells, 'OneTime'
    spec.top = true                        -- BUG-515: first in the work orders, not behind the weapons that fill the forge
    local ok, id = K.act.workorder(spec)
    if ok then done = 'ordered'; p.chain_o = id end
  end
  if due and #need > 0 then
    local okp, pend = K.call('runner', 'pending', 'workshops')
    if not (okp and type(pend) == 'number' and pend > 0) then
      K.emit('PROJECT_REQUEST', 'B', trunc(string.format('workshops: %s for the rope/chain of well %d (%s)',
                                                          table.concat(need, ', '), wells[1].id, route), 200),
             {tpl = 'workshops', n = 1, why = 'well', types = need})
      done = 'requested'
    end
  end
  if due then p.chain_t = now end
  local w = wells[1]
  local how = ({metal = string.format('a chain of %s (%d bars)', tostring(tok), bars),
                cloth = string.format('a cloth rope (%d cloth)%s', cloth, #need > 0 and ', no Clothiers' or ''),
                thread = string.format('a rope: thread %d, no cloth: %s', thread, #need > 0 and table.concat(need, '+')
                                       or 'weave cloth'),
                forge = string.format('a chain: %d bars, no Metalsmith\'s forge', bars),
                trade = 'no metal, cloth or thread: buy rope or a chain (trade.want chain)'})[route]
  local txt = trunc(string.format('well %d at %d,%d,%d waits for a chain: %s%s', w.id, w.x, w.y, w.z, how,
                                  done and (', ' .. done) or ''), 120)
  if not st.chain or st.chain.route ~= route then K.log('warn', 'water: %s', txt) end
  st.chain = {n = #wells, well = w.id, route = route, need = need, txt = txt, order = live or p.chain_o}
  return st.chain
end

---------------------------------------------------------------- BUG-263/266: why no water is accepted
-- the source the last accepted water was (p.slast) and why it dropped out, while nothing is accepted now
function M.dropped(r, p)
  local ls = type(p.slast) == 'table' and p.slast or nil
  if not ls then return nil end
  for _, s in ipairs(r.sources) do if s.wet then return nil end end
  local why = 'gone'
  for _, s in ipairs(r.sources) do
    if s.kind == ls.k and s.id == ls.id then
      why = s.loop and string.format('fed only by its own pond %d: a loop', s.loop)
            or (s.below and s.below.why == 'shallow' and string.format('shallow now (%d/7)', s.below.flow or 0))
            or 'dry now'                                                       -- BUG-344 review
    end
  end
  local at = type(ls.at) == 'table' and string.format('%d,%d,%d', math.tointeger(ls.at[1]) or -1,
                                                      math.tointeger(ls.at[2]) or -1, math.tointeger(ls.at[3]) or -1) or '?'
  return string.format('the accepted %s %d at %s dropped out (%s)', tostring(ls.k), math.tointeger(ls.id) or -1, at, why)
end

-- BUG-266 (Run 15 Drillchamber y372: 'Kern+ refused: drink 0<17 (1 well, none wet)', well 17718 not accepted): fortcore
-- stage 1 builds its well over a 2-tile sump that only bucket carriers fill (its pond zone); no water check. The first
-- built, dry well outside a cistern room, what its shaft ends on and where a carrier could fill its sump from (the
-- scan's nearest body with a reachable bank), nil without one
function M.dry_well(K, c, r)
  local boxes = {}
  for _, rm in ipairs(K.manifest().rooms or {}) do
    if rm.tpl == 'cistern' and type(rm.bbox) == 'table' then boxes[#boxes + 1] = rm.bbox end
  end
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' and s.built and not s.water then
      local inc = false
      for _, b in ipairs(boxes) do
        if s.z == b[3] and s.x >= (b[1] or 0) and s.x <= (b[4] or -1) and s.y >= (b[2] or 0) and s.y <= (b[5] or -1) then
          inc = true
        end
      end
      if not inc then
        local bl = s.below or {}
        local what = bl.why == 'rock' and 'rock below' or (bl.why == 'hidden' and 'a hidden tile below'
                     or (bl.why == 'shallow' and string.format('%d/7 below, shallow: < %d/7', bl.flow or 0, c.well_min or 3)
                     or string.format('%d/7', bl.flow or 0)))
        local best
        for _, b in ipairs(st.ws and st.ws.bodies or {}) do      -- BUG-324: a well spot's floor is a bank one level up
          if b.cavern ~= 1 and (b.bank or b.stand) and (not best or b.d < best.d) then best = b end
        end
        local bk = best and (best.bank or best.stand)
        local fill = best and string.format('fill source: the water at %d,%d,%d (bank %d,%d,%d)', best.at[1], best.at[2],
                                            best.at[3], bk[1], bk[2], bk[3])
                     or 'no water a carrier reaches to fill it'
        return string.format('dry well %d at %d,%d,%d (%s): only buckets fill its sump; %s', s.id, s.x, s.y, s.z, what,
                             fill)
      end
    end
  end
end

function M.dry_causes(K, c, r, p)
  local out = {}
  local d = M.dropped(r, p)
  if d then out[#out + 1] = d end
  local lc = M.loop_cause(r)
  if lc and not (d and d:find('a loop', 1, true)) then out[#out + 1] = lc end
  local dw = M.dry_well(K, c, r)
  if dw then out[#out + 1] = dw end
  if st.chain then out[#out + 1] = st.chain.txt end
  return out, dw
end

-- BUG-262: the highest level the kernel saw damp or wet (manifest aquifer_levels), nil without one. BUG-291: also a level
-- the water scan saw a revealed aquifer tile beside water on (m.water aqz; the runner adds it to the manifest)
function M.aq_level(K)
  local best
  local ok, man = pcall(K.manifest)
  local okp, p = pcall(K.persist.get, 'm.water')
  for _, list in ipairs({ok and type(man) == 'table' and type(man.aquifer_levels) == 'table' and man.aquifer_levels or {},
                         okp and type(p) == 'table' and type(p.aqz) == 'table' and p.aqz or {}}) do
    for _, z in ipairs(list) do
      if math.tointeger(z) and (not best or z > best) then best = z end
    end
  end
  return best
end

local function finish(K, c, r, p)
  local now = K.now().tick
  local T = K.now()
  pond_loops(K, c, r, p)
  M.loops(K, c, r, p)                                   -- BUG-263: a well fed only by its own pond is no accepted source
  local hosp_ok, best_h, dry_h = #r.hosp > 0, nil, nil
  for _, h in ipairs(r.hosp) do
    local ok, b = served(K, c, r, h)
    if not ok then hosp_ok, dry_h = false, dry_h or h end
    if b and (not best_h or b.d < best_h.d) then best_h = b end
  end
  local refuge, rname = burrow(K, 'refuge', 'Tiefe+')
  local kern, kname = burrow(K, 'kern', 'Kern+')
  local ho = M.hosp_sort(K, r, hospital_out(r, kern, refuge, kname, rname))    -- BUG-036, BUG-131
  st.hout, st.hz = ho, r.hosp
  M.care_step(K, c, r, now)                             -- BUG-330: the care burrow before the texts that name it
  patients_out(K, r, kern, refuge, kname, rname, ho)
  local refuge_ok, rwells, rwet = false, 0, 0          -- BUG-035: the wells in the refuge and the wet ones of them
  for _, s in ipairs(r.sources) do
    -- BUG-040: the burrow each source stands on (Kern+ first, else the refuge): state water.src_l, M.label
    s.inn = on_burrow(kern, s.x, s.y, s.z) and kname or (on_burrow(refuge, s.x, s.y, s.z) and rname or nil)
    if s.kind == 'well' and on_burrow(refuge, s.x, s.y, s.z) then
      rwells = rwells + 1
      if s.water then rwet, refuge_ok = rwet + 1, true end         -- BUG-263: a stored drink counts for the refuge
    end
  end
  local wells, wet = 0, 0
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' then wells = wells + 1 end
    if s.wet then wet = wet + 1 end
  end
  local wz = wet == 0 and M.zone_found(K, c, r, p, now) or nil      -- BUG-324: zone the water the scan found
  -- buckets: the hospital's own wish, at least buckets_min, one more per patient
  local want = c.buckets_min
  for _, h in ipairs(r.hosp) do if h.want and h.want > want then want = h.want end end
  want = math.min(c.buckets_max, want + c.bucket_per_patient * #r.patients)
  local fixed, ordered, missing = supply_buckets(K, c, r, p, want)
  M.chain(K, c, r, p, now)                              -- BUG-264: a well that waits for its chain or rope
  -- BUG-054: caregivers scale with the patients (before the cause text: it names what was added)
  local over_alarm = false
  for _, pt in ipairs(r.patients) do if pt.thirst > c.thirst_alarm then over_alarm = true end end
  local cs = M.carers(K, c, r, p, now, over_alarm)
  local after = cs.have_after or cs.have
  -- BUG-104: the game's GiveWater jobs, read once a run while a patient lies in a bed (their age is kept from the first
  -- run on, so 'stuck' is known when the alarm sounds); the diagnosis only when a patient is over the alarm
  local sc
  if #r.patients > 0 then sc = M.job_scan(p, now, c.give_stuck_days) else p.gj = json.object() end
  local need_gv = over_alarm
  for _, pt in ipairs(r.patients) do if pt.thirst >= c.dying_thirst then need_gv = true end end
  local gv
  if not need_gv then p.grun = nil end
  if need_gv then
    local top
    for _, pt in ipairs(r.patients) do if not top or pt.thirst > top.thirst then top = pt end end
    gv = M.give_effect(p, M.give_diag(K, c, r, sc, r.free + fixed, top), top, now, best_h)   -- BUG-343
    st.gv = {tick = now, key = gv.key, txt = gv.txt, reason = gv.reason}
  end
  local rel = M.restale(K, c, r, p, now, gv, sc)                      -- BUG-383
  if rel and gv then gv.reason = rel .. '; ' .. gv.reason end              -- first: the lines are cut at 200
  local okst, errst = pcall(M.stalls, K, c, r, p, now)                -- BUG-507/508
  if not okst then K.log('warn', 'water stalls: %s', tostring(errst)) end
  local okrs, errrs = pcall(M.restore, K, c, r, p, now)                   -- BUG-539
  if not okrs then K.log('warn', 'water restore: %s', tostring(errrs)) end
  st.last = r
  -- patients over the alarm: one class-A line for all of them, with the cause (cadence: M.DEFAULTS)
  local thirsty, tmax = 0, 0
  local dry = not hosp_ok and #r.hosp > 0
  local cause = {}
  if #r.hosp == 0 then cause[#cause + 1] = 'no hospital zone' end
  local cis = dry and cistern_state(K, c, r, dry_h) or nil              -- BUG-031: why the cistern does not count
  if dry then
    cause[#cause + 1] = best_h and string.format('nearest accepted water %d tiles from the hospital', best_h.d)
                        or 'no wet well or deep (>= ' .. c.deep .. '/7) Water Source zone'
    if cis then cause[#cause + 1] = cis.txt end
  end
  if wet == 0 then cause[#cause + 1] = 'no accepted water at all' end
  if wz then cause[#cause + 1] = wz.txt end                             -- BUG-324: what the kernel did about it
  -- BUG-263/264/266: why there is none: the source the hospital was placed by dropped out, a well fed by its own pond, a
  -- plain well over a dry sump (fortcore stage 1: only buckets fill it), a well that waits for its chain or rope
  local extra, dwell = {}, nil
  if dry or wet == 0 then extra, dwell = M.dry_causes(K, c, r, p) end
  for _, e in ipairs(extra) do cause[#cause + 1] = e end
  if r.free + fixed == 0 then              -- BUG-104: in counts (a bucket that holds water or is forbidden is no free one)
    cause[#cause + 1] = string.format('no free bucket (%d in the fort, %d hold water, %d forbidden)', r.buckets, r.full,
                                      #r.forbidden)
  end
  local gerr = cs.err and #cs.added == 0 and (' (could not add: ' .. trunc(cs.err, 60) .. ')') or ''
  if after == 0 and #r.patients > 0 then
    cause[#cause + 1] = 'no caregiver with FEED_WATER_CIVILIANS' .. gerr
  elseif cs.want > after then              -- BUG-054: 4 caregivers for 5 patients are not "present"
    cause[#cause + 1] = string.format('caregivers short: %d of %d wanted for %d patient(s)%s', after, cs.want,
                                      #r.patients, #cs.added > 0 and string.format(', %d added to %s now', #cs.added,
                                                                                    M.CARER_DETAIL) or gerr)
  elseif #cs.added > 0 then
    cause[#cause + 1] = string.format('caregivers raised to %d (%d added to %s now)', after, #cs.added, M.CARER_DETAIL)
  end
  if gv and not dry then table.insert(cause, 1, gv.reason) end         -- BUG-104: the verdict first (the lines are cut at 200)
  local why = #cause > 0 and table.concat(cause, ', ') or 'water, buckets and caregivers present'
  -- FR-34: the one-line recipe (Run 9: deleting the hospital zone made the survivor stand up, drink and eat; Run 11:
  -- GiveWater jobs ran again, BUG-034). With the removal on, a dry hospital is left only when the removal failed
  local recipe = dry and 'delete the hospital zone (GiveWater resumes or patients fetch their own drink) or carry water'
                 or (gv and gv.txt) or 'check the GiveWater jobs: caregivers, buckets, the way to the water'
  local carers = {}
  for i = 1, math.min(8, #r.carers) do carers[i] = r.carers[i] end
  -- BUG-034: a dry hospital's zones go before the patients die (HOSPITAL_REMOVED carries the patients: no patient_thirst
  -- and no HOSPITAL_DRY in the same run)
  local removed = dry and remove_dry(K, c, r, p, T) or nil
  -- a day after a removal: how many GiveWater jobs run now (the DF rule the removal rests on, BUG-034)
  local rm = p.rm
  if type(rm) == 'table' and rm.after == nil and math.tointeger(rm.t) and now - rm.t >= DAY then
    local tm = 0
    for _, pt in ipairs(r.patients) do if pt.thirst > tm then tm = pt.thirst end end
    rm.after, rm.tmax_after = r.give, tm
    K.log('info', 'water: a day after the hospital removal (tick %d): %d GiveWater job(s), %d patient(s), max thirst %d '
          .. '(was %d)', rm.t, r.give, #r.patients, tm, math.tointeger(rm.tmax) or -1)
  end
  -- p.alarm: patients over the alarm in this episode (id -> tick they crossed it)
  local over, fresh = {}, false
  for _, pt in ipairs(r.patients) do
    if pt.thirst >= c.thirst_watch then thirsty = thirsty + 1 end
    if pt.thirst > tmax then tmax = pt.thirst end
    if pt.thirst > c.thirst_alarm then
      over[#over + 1] = pt
      local sid = fmt(pt.id)
      if not p.alarm[sid] then p.alarm[sid], fresh = now, true end
    end
  end
  for sid in pairs(p.alarm) do
    local keep = false
    for _, pt in ipairs(over) do if fmt(pt.id) == sid then keep = true end end
    if not keep then p.alarm[sid] = nil end
  end
  local woke = false
  -- BUG-596 (Brotherarrow y406-y414: the same patient_thirst line 14 times, 'the civ alert holds the caregivers in Tiefe+, the patient lies outside;
  -- Pflege+ not opened', nothing a decision could change): while the cause is the alert and the care burrow stays closed the weekly reminder
  -- comes at ALERT_REPEAT times the interval; a patient crossing the alarm still wakes at once
  local alarm_gap = c.alarm_every
  if gv and gv.key == 'alert' and not (st.care and st.care.on) then alarm_gap = c.alarm_every * M.ALERT_REPEAT end
  -- BUG-008: the weekly reminder also waits wake_wall_s wall seconds (a game week is 21 s at timestream speed); a
  -- patient crossing the alarm still wakes at once
  if removed then
    p.alarm_t, p.alarm_w, woke = now, T.wall, true            -- HOSPITAL_REMOVED named them (BUG-034)
  elseif #over > 0 and (fresh or CAD.elapsed({t = p.alarm_t or -c.alarm_every, w = p.alarm_w}, T, alarm_gap,
                                             c.wake_wall_s)) then
    p.alarm_t, p.alarm_w, woke = now, T.wall, true
    table.sort(over, function(a, b) return a.thirst > b.thirst end)
    local ids = {}
    for i = 1, math.min(8, #over) do ids[i] = over[i].id end
    local top = over[1]
    local msg = string.format('%d patient(s) over thirst %d, unit %d at %d: %s; %s', #over, c.thirst_alarm, top.id,
                              top.thirst, why, recipe)
    if gv and not dry and #msg > 200 then   -- BUG-104: the counts matter more than the buckets
      msg = string.format('%d patient(s) over thirst %d, unit %d at %d: %s; %s', #over, c.thirst_alarm, top.id,
                          top.thirst, why, gv.short)
    end
    local q = string.format('units %s thirsty: %s; carers %d of %d wanted (FEED_WATER_CIVILIANS: %s), buckets %d free of %d; %s',
                            table.concat(ids, ','), recipe, after, cs.want, #carers > 0 and table.concat(carers, ',') or 'none',
                            r.free + fixed, r.buckets, why)
    if gv and not dry then                  -- BUG-104: the reason and the counts first, the ids last (the text is cut at 200)
      local rest = {}
      for i = 2, #cause do rest[#rest + 1] = cause[i] end
      q = string.format('%s; %s, %s; buckets %d free of %d; carers %d of %d wanted (FEED_WATER_CIVILIANS: %s); units %s%s',
                        gv.reason, gv.jobs_t, gv.reach_t, r.free + fixed, r.buckets, after, cs.want,
                        #carers > 0 and table.concat(carers, ',') or 'none', table.concat(ids, ','),
                        #rest > 0 and ('; ' .. table.concat(rest, ', ')) or '')
    end
    local d = {id = 'patient_thirst', unit = top.id, thirst = top.thirst, units = ids, n = #over, carers = carers,
               n_carers = after, want = cs.want, added = #cs.added, buckets = r.free + fixed, buckets_all = r.buckets,
               q = trunc(q, 200)}
    if gv then d.open, d.run, d.stuck, d.reach, d.key, d.idle = gv.open, gv.run, gv.stuck, gv.reach, gv.key, gv.idle end
    d.cmds = M.patient_cmds(gv, top)               -- BUG-449: a decision names what can be run
    if gv and gv.unrel then d.unrel = trunc(gv.unrel, 60) end
    K.emit('DECISION_NEEDED', 'A', trunc(msg, 200), d)
  end
  -- BUG-054: a patient at the death-risk line (dying_thirst; death follows at ~75,000) is a class-A line of its own, with
  -- the caregivers' state; the cadence rule (util/cadence.lua): at once for a new patient or a changed cause, else not
  -- before dying_every ticks and the wall-clock wait
  local dying, dids = {}, {}
  for _, pt in ipairs(r.patients) do
    if pt.thirst >= c.dying_thirst then dying[#dying + 1] = pt end
  end
  if #dying > 0 then
    table.sort(dying, function(a, b) return a.thirst > b.thirst end)
    for i, pt in ipairs(dying) do dids[i] = pt.id end
    local hs = #r.hosp == 0 and 'none' or (hosp_ok and 'ok' or 'dry')
    local toks = {'hospital ' .. hs, after >= cs.want and 'caregivers enough' or 'caregivers short',
                  r.free + fixed > 0 and 'buckets' or 'no buckets', r.give > 0 and 'giving' or 'nobody giving'}
    if gv then toks[#toks + 1] = 'give ' .. gv.key end                 -- BUG-104: a changed reason is news
    if CAD.due(p.dying, T, dids, toks, {ticks = c.dying_every, wall_s = c.wake_wall_s}) then
      p.dying = CAD.mark(T, dids, toks)
      local gopen, grun
      if gv and gv.open ~= nil then gopen, grun = gv.open, gv.run else gopen, grun = M.give_jobs() end
      local top = dying[1]
      local lie = M.lie(K, df.unit.find(top.id))                        -- BUG-343: wounds, syndromes
      local shown = {}
      for i = 1, math.min(8, #dids) do shown[i] = dids[i] end
      local msg = string.format('%d patient(s) near death of thirst (>= %d), unit %d at %d: hospital %s, caregivers %d of %d '
                                .. 'wanted (%d idle), %d giving water; %s', #dying, c.dying_thirst, top.id, top.thirst, hs,
                                after, cs.want, cs.idle, r.give, why)
      K.emit('PATIENT_DYING', 'A', trunc(msg, 200),
             {units = shown, n = #dying, thirst = top.thirst, carers = after, want = cs.want, hosp = hs,
              idle = cs.idle, added = #cs.added, give = r.give, open = gopen or -1, run = grun or -1,
              buckets = r.free + fixed, why = trunc(why, 120), stuck = gv and gv.stuck or nil,
              reach = gv and gv.reach or nil, key = gv and gv.key or nil, lie = lie ~= '' and trunc(lie, 120) or nil,
              cmds = M.patient_cmds(gv, top), unrel = gv and gv.unrel and trunc(gv.unrel, 60) or nil})
      K.log('warn', 'water: %s (GiveWater/GiveFood jobs: %s open, %s running)%s%s', msg, tostring(gopen), tostring(grun),
            gv and ('; ' .. gv.txt) or '', lie ~= '' and ('; unit ' .. top.id .. ': ' .. lie) or '')
    end
  else
    p.dying = CAD.quiet(p.dying)
  end
  -- hospital gate (FR-31/34): a hospital location, or a hospital project while no accepted water exists at all,
  -- without an accepted source wakes the LLM when the dry episode starts (not in a run that sent patient_thirst);
  -- a cistern is asked monthly either way. BUG-008: within an episode again only when a patient joined or a new
  -- cause appeared, and not before max(hosp_every with patients, else gate_every, wake_wall_s wall seconds)
  local okh, hpend = K.call('runner', 'pending', 'hospital')
  local planned = #r.hosp == 0 and okh and type(hpend) == 'number' and hpend > 0
  local gate = dry or (planned and wet == 0)
  -- BUG-288 (Run 15 Inkintense: no hospital zone, no accepted water, the scan ran only on an inspect): a fort without
  -- accepted water scans weekly too (the recipe, the well spots, the aquifer level come from it)
  if wet == 0 and (not st.ws or now - st.ws.tick >= c.ws_every) and not st.scan then st.ws_want = true end
  if gate then
    p.hosp_ok = nil                                        -- BUG-537: the water is gone again: the clear clock restarts
    if (not st.ws or now - st.ws.tick >= c.ws_every) and not st.scan then st.ws_want = true end
    local every = #r.patients > 0 and c.hosp_every or c.gate_every
    local start = p.hosp == nil
    p.hosp = p.hosp or now
    local pids, toks = {}, {}
    for i, pt in ipairs(r.patients) do pids[i] = pt.id end
    for i, cs in ipairs(cause) do
      local t = cs:gsub('%d+', 'N')                                        -- a distance is no new cause
      if t:find('^caregivers short') then t = 'caregivers short'           -- BUG-054: nor is how many were added now
      elseif t:find('^caregivers raised') then t = 'caregivers raised' end
      toks[i] = t
    end
    if planned then toks[#toks + 1] = 'planned' end
    local last = p.hosp_t and {t = p.hosp_t, w = p.hosp_w, ids = p.hosp_ids or {}, toks = p.hosp_toks or {}} or nil
    if woke then
      p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks = now, T.wall, pids, toks   -- patient_thirst carried cause and recipe
    elseif start or CAD.due(last, T, pids, toks, {ticks = every, wall_s = c.wake_wall_s}) then
      p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks = now, T.wall, pids, toks
      local h = r.hosp[1]
      local a = {planned = planned, patients = #r.patients, zone = h and h.id or -1,
                 why = planned and ('no accepted water on the map' .. (#extra > 0 and (': ' .. table.concat(extra, ', '))
                                                                       or '')) or why, cis = cis, lost = extra[1],
                 dw = dwell}
      if not st.ws and has_liquids(K) then
        st.gate_pending, st.ws_want = a, true             -- the first one waits for the scan's recipe (a few frames)
      else
        emit_gate(K, c, a)
      end
    end
    local okp, pend = K.call('runner', 'pending', 'cistern')
    -- BUG-031: a cistern within reach of the hospital needs water, not a second cistern (the recipe says how)
    if not (okp and type(pend) == 'number' and pend > 0) and not (cis and cis.near)
       and now - (p.req or -c.request_every) >= c.request_every then
      p.req = now
      K.emit('PROJECT_REQUEST', 'B', 'cistern: the hospital has no accepted water within ' .. c.near .. ' tiles',
             {tpl = 'cistern', n = 1, why = 'hospital_water'})
    end
  elseif p.hosp ~= nil then
    -- BUG-537: accepted water for the first time since the episode began starts the clear clock; the episode (and with it the
    -- wake at its start) ends after gate_clear ticks of it. A well that reads 3/7 and 1/7 in turn is one episode.
    p.hosp_ok = p.hosp_ok or now
    if now - p.hosp_ok >= (math.tointeger(c.gate_clear) or 0) then
      p.hosp, p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks, p.hosp_ok = nil, nil, nil, nil, nil, nil   -- a new dry episode wakes at once
    end
  end
  -- BUG-434: patients thirsty with no accepted water within patient_far tiles of them: the cistern is asked for whatever hospital zone
  -- there is (or not: the gate above needs a hospital zone or project). Nothing while a cistern project is pending
  local pf = math.tointeger(c.patient_far) or 0
  if pf > 0 and thirsty > 0 then
    local worst, wd
    for _, pt in ipairs(r.patients) do
      if pt.x and pt.thirst >= c.thirst_watch then
        local d = M.source_dist(r, pt)
        if not d or d > pf then
          if not worst or pt.thirst > worst.thirst then worst, wd = pt, d end
        end
      end
    end
    if worst then
      local okq, pend = K.call('runner', 'pending', 'cistern')
      if not (okq and type(pend) == 'number' and pend > 0) and now - (p.req or -c.request_every) >= c.request_every then
        p.req = now                       -- the hospital gate's cadence: one cistern request per request_every, whoever asks
        local acc = M.drink_access(K)
        local near = type(acc) == 'table' and acc.near or nil
        local msg = string.format('cistern: patient %d (thirst %d) has %s', worst.id, worst.thirst,
                                  wd and string.format('no accepted water within %d tiles (nearest %d)', pf, wd)
                                  or 'no accepted water at all')
        local data = {tpl = 'cistern', n = near and acc.nd or wd or 1, why = 'patient_water'}
        if near then data.at = json.array{near[1], near[2], near[3]} end
        K.emit('PROJECT_REQUEST', 'B', trunc(msg, 200), data)
        K.log('warn', 'water: %s; %d patient(s) over thirst %d, %d hospital zone(s): GiveWater needs water, not a zone', msg,
              thirsty, c.thirst_watch, #r.hosp)
      end
    end
  end
  -- a cistern that floods its well room (the breaker failed or something was dug into the pipe). One wet tile
  -- in one run is no flood: a bucket poured into a dry cistern's pond hole shows water there for a moment
  local wet_rooms = {}
  for _, rm in ipairs(K.manifest().rooms or {}) do
    if rm.tpl == 'cistern' and type(rm.bbox) == 'table' and type(rm.id) == 'string' then
      local b, first, n = rm.bbox, nil, 0
      for y = b[2], b[5] do
        for x = b[1], b[4] do
          local t = tile(K, x, y, b[3])
          if t and wet_char(t.c) then n = n + 1; first = first or {x, y, b[3]} end
        end
      end
      if n > 0 then wet_rooms[rm.id] = true end
      local flooded = n >= c.flood_tiles or (n > 0 and (st.wet_rooms or {})[rm.id])
      if flooded and now - (p.flood or -c.flood_every) >= c.flood_every then
        p.flood = now
        K.emit('DECISION_NEEDED', 'A', trunc(string.format('cistern %s floods its well room: %d wet tiles from '
                                                           .. '%d,%d,%d', rm.id, n, first[1], first[2], first[3]), 200),
               {id = 'cistern_flood', q = trunc('close the floodgate (the lever in the well room ' .. rm.id
                                                .. '), stop filling its pond zone, keep dwarves out', 200)})
      end
    end
  end
  st.wet_rooms = wet_rooms
  cistern_dry(K, c, r, p, now)                        -- BUG-040: a done cistern whose well stays dry
  -- the hospital zones left after this run's removal, and whether every one of them is served (BUG-034)
  local nh = #r.hosp
  if removed then
    local gone = {}
    for _, id in ipairs(removed.zones) do gone[id] = true end
    nh, hosp_ok = 0, true
    for _, h in ipairs(r.hosp) do
      if not gone[h.id] then
        nh = nh + 1
        if not served(K, c, r, h) then hosp_ok = false end
      end
    end
    hosp_ok = hosp_ok and nh > 0
  end
  local srcs, slbl, s1 = src_list(r)
  -- BUG-263: the nearest accepted source is remembered until another one is accepted: when none is left, HOSPITAL_DRY
  -- names the one the hospital was placed by and why it dropped out (M.dry_causes)
  if s1 then p.slast = {k = s1.kind, id = s1.id, at = json.array{s1.x, s1.y, s1.z}, t = now} end
  local out = {patients = #r.patients, thirsty = thirsty, thirst_max = tmax, wells = wells, wet = wet,
               hosp_ok = hosp_ok and 1 or 0, refuge_ok = refuge_ok and 1 or 0, buckets = r.buckets,
               buckets_free = r.free + fixed, buckets_full = r.full, buckets_want = want, unforbid = fixed,
               ordered = ordered, missing = math.max(0, missing), carers = after, gate = gate and 1 or 0,
               hosp = nh, give = r.give, removed = removed and #removed.zones or 0, src = srcs, src_l = slbl,
               rwells = rwells, rwet = rwet, hosp_out = ho.n}
  -- BUG-056 (Run 11: 8 HOSPITAL locations stayed after their zones were deleted): a hospital is a location with a zone;
  -- every count here (r.hosp, hosp, hosp_out, the dry gate, the removal) goes by zones, a zoneless location is only counted
  local live_locs, nlive = {}, 0
  for _, h in ipairs(r.hosp) do
    if not live_locs[h.loc] then live_locs[h.loc], nlive = true, nlive + 1 end
  end
  out.locs = {total = r.locs_total or nlive, live = nlive, stale = math.max(0, (r.locs_total or nlive) - nlive)}
  if out.locs.stale ~= (st.stale_locs or 0) then
    st.stale_locs = out.locs.stale
    if out.locs.stale > 0 then
      K.log('info', 'water: %d hospital location(s) without a zone are left alone (%d with zones; BUG-056)',
            out.locs.stale, nlive)
    end
  end
  out.cw = {have = after, want = cs.want, idle = cs.idle, give = r.give, mine = cs.mine, err = cs.err}   -- BUG-054, inspect
  local prev = st.out or {}
  if prev.hosp_ok ~= out.hosp_ok or prev.refuge_ok ~= out.refuge_ok or prev.patients ~= out.patients
     or prev.hosp ~= out.hosp or prev.rwells ~= out.rwells or prev.hosp_out ~= out.hosp_out or fixed > 0
     or ordered > 0 then
    -- BUG-035 (Run 11: 'refuge dry, 1 wet sources (13 wells)'): where the wells are relative to the refuge
    local rw = string.format('%d %s, %d in %s', wells, wells == 1 and 'well' or 'wells', rwells, rname)
    if rwells > 0 then rw = rw .. string.format(', %d of them wet', rwet) end
    K.log('info', 'water: %d patients (max thirst %d), hospital %s, refuge %s (%s), %d wet sources, buckets %d free of %d '
          .. '(want %d, unforbid %d, ordered %d), %d GiveWater', out.patients, tmax,
          nh == 0 and 'none' or (hosp_ok and 'ok' or 'dry') .. (ho.n > 0 and string.format(' (%d of %d zones outside %s/%s)',
          ho.n, ho.total, kname, rname) or ''), refuge_ok and 'ok' or 'dry', rw, wet, out.buckets_free,
          r.buckets, want, fixed, ordered, r.give)
  end
  -- BUG-106: the hospital audit of this run (inspect what=hospital, the state's water.gaps); never lets the run fail
  local oka, audit = pcall(M.audit, K, c, r, {dry = dry, best = best_h, ho = ho, after = after, idle = cs.idle})
  if oka then
    st.audit = audit
    st.audit.give = st.gv and {tick = st.gv.tick, key = st.gv.key, txt = st.gv.txt} or nil
    local oks, errs = pcall(M.supply_ask, K, c, p, audit)     -- BUG-537
    if not oks then K.log('warn', 'water: hospital supply ask failed: %s', tostring(errs)) end
  else
    K.log('warn', 'water: hospital audit failed: %s', tostring(audit))
  end
  st.out = out
  -- BUG-344 review: a built well over water below well_min is no source; one kern.log line per shallow spell
  p.shal = json.object(type(p.shal) == 'table' and p.shal or {})
  local shal = {}
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' and s.below and s.below.why == 'shallow' then
      shal[tostring(s.id)] = true
      if not p.shal[tostring(s.id)] then
        p.shal[tostring(s.id)] = now
        K.log('warn', 'water: well %d at %d,%d,%d is shallow: %d/7 below (< well_min %d/7), no drink source', s.id, s.x,
              s.y, s.z, s.below.flow or 0, c.well_min)
      end
    end
  end
  for id in pairs(p.shal) do if not shal[id] then p.shal[id] = nil end end
  st.src = r.sources
  st.thirsty = r.thirsty                                    -- BUG-344
  K.persist.touch('m.water')
end

---------------------------------------------------------------- module
local PHASES = {phase_units, phase_sites, phase_buckets}

local function new_run(K)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  return {ph = 1, idx = 0, ids = ids, patients = {}, sources = {}, hosp = {}, buckets = 0, free = 0, full = 0,
          forbidden = {}, ponds = {}, carers = {}, home = {}, give = 0, pool = {}, carers_idle = 0, cpos = {}, doc = {},
          outsiders = 0, bpos = {}, thirsty = {}}
end

function M.init(K)
  st = {run = nil}
  pstate(K)
end

-- BUG-448 (Run 16d i4 Mazelanterns y404: the aqshaft and the cistern 100 % done, `bp sites hospital --fresh` still 'no accepted water', the
-- water scan 7.3 M ticks old and 'queued for the next water run'): a finished aqshaft or cistern changes the water the fort reaches. The
-- scan is queued at once and, as a cistern fills, once more ws_redo ticks later (state m.water ws_redo, kept over reloads)
M.on['EV:PROJECT_DONE'] = function(K, ev)
  local d = type(ev) == 'table' and type(ev.d) == 'table' and ev.d or {}
  if d.tpl ~= 'aqshaft' and d.tpl ~= 'cistern' then return end
  local c = M.conf(K)
  local now = K.now().tick
  st.ws_want = true
  if c.ws_redo > 0 then
    pstate(K).ws_redo = now + c.ws_redo
    K.persist.touch('m.water')
  end
  K.log('info', 'water: %s %s finished: the water sources scan is queued%s', tostring(d.tpl), tostring(d.proj),
        c.ws_redo > 0 and ' (and once more in a few days)' or '')
end

-- the run (patients, sources, buckets, decisions), then a requested water sources scan in the following frames;
-- a scan that outlasts the cadence lets the next run go first
function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  local now = K.now().tick
  M.care_check(K)                                         -- BUG-330 review: the open care burrow on every step
  if not (ctx and ctx.cont) or (not st.run and not st.scan) then
    st.run, st.run_t = new_run(K), now
  elseif not st.run and now - (st.run_t or now) >= M.every.ticks then
    st.run, st.run_t = new_run(K), now
  end
  local r = st.run
  local redo = math.tointeger(p.ws_redo)                  -- BUG-448: the second scan after a finished aqshaft / cistern
  if redo and now >= redo then
    p.ws_redo = nil
    K.persist.touch('m.water')
    if not st.scan then st.ws_want = true end
  end
  -- BUG-288 (Run 15 Inkintense: 'scan queued' for a season): the scan in hand gets a slice in every step. It used to wait
  -- for a step without a run, and with the slices paced 30 s apart every step began a new run (1200 ticks had passed):
  -- the scan never moved while the game ran
  if st.scan then
    local ok, more = pcall(scan_step, K, c, p)
    if not ok then
      K.log('warn', 'water sources scan: %s', tostring(more))
      st.ws = st.ws or {tick = now, deep = c.deep, boxes = {}, tiles = 0, levels = {}, bodies = {}, err = 'scan failed'}
    end
    if not (ok and more) then st.scan = nil end
  end
  if r then
    while r.ph <= #PHASES do
      if not PHASES[r.ph](K, c, r) then return 'more' end
      r.ph, r.idx = r.ph + 1, 0
    end
    st.run = nil
    finish(K, c, r, p)
    if st.ws_want and not st.scan then
      st.ws_want = nil
      st.scan = new_scan(K, c, r, p)
      if not st.scan then                -- nobody to scan around: say so instead of 'queued' for good
        st.ws = {tick = now, deep = c.deep, boxes = {}, tiles = 0, levels = {}, bodies = {},
                 err = 'no hospital zone and no citizen position to scan around'}
      end
    end
  end
  if st.gate_pending and not st.scan then                 -- the gate alarm that waited for the scan
    emit_gate(K, c, st.gate_pending)
    st.gate_pending = nil
  end
  if st.scan then return 'more' end
end

-- inspect what=water_sources (kern routes it here; FR-47): the last scan (bodies of water >= deep per level with
-- an accepted zone or well, a reachable bank or the shortest dig), the sources of the last run; a scan older than
-- ws_every (or none) is queued for the next water run
function M.inspect(K, what, key)
  if what == 'hospital' then return M.inspect_hospital(K) end              -- BUG-106
  if what ~= 'water_sources' then return false, 'water answers what=water_sources and what=hospital only' end
  local c = M.conf(K)
  local now = K.now().tick
  if (not st.ws or now - st.ws.tick >= c.ws_every) and not st.scan then st.ws_want = true end
  local srcs = {}
  for _, s in ipairs(st.src or {}) do        -- BUG-040: + the depth of the water under a well (-1 unknown) and its burrow
    if #srcs < 30 then
      srcs[#srcs + 1] = {s.kind, s.id, s.x, s.y, s.z, s.wet and 1 or 0,
                         s.below and math.tointeger(s.below.flow) or -1, s.inn or ''}
    end
  end
  -- BUG-040: where the refuge lies and how far its nearest tile is from the nearest accepted water (seal's audit)
  local okr, rd = K.call('seal', 'refuge_drink')
  local ref
  if okr and type(rd) == 'table' and type(rd.box) == 'table' then
    local n = type(rd.near) == 'table' and rd.near or nil
    ref = {name = rd.name, box = rd.box, d = n and n.d or -1, at = n and n.at or nil,
           src = n and n.src and M.label(K, n.src[1], n.src[2], n.src[3]) or nil, wells = rd.wells, wet = rd.wwet}
  end
  local queued = (st.ws_want or st.scan) and 1 or 0
  local ps = pstate(K)
  local rm = ps.rm                            -- BUG-034: the last dry hospital removal (zones, patients, GiveWater jobs)
  rm = type(rm) == 'table' and rm or nil
  -- BUG-288: when a scan last finished (kept over reloads) and how far the running one is (stage, slices so far, at most)
  local last = type(ps.ws_last) == 'table' and ps.ws_last or nil
  local sc = st.scan
  local run = sc and {stage = sc.stage, slices = sc.slices, max = c.ws_slices + c.ws_body_slices + 2, reads = sc.reads}
              or nil
  local lt = last and math.tointeger(last.t)
  local since = lt and string.format('last finished at tick %d, %d ticks ago', lt, now - lt) or 'none finished yet'
  if not st.ws then
    local what = sc and string.format('scan running (%s, slice %d of at most %d)', sc.stage, sc.slices, run.max)
                 or 'scan queued for the next water run'
    return true, string.format('water_sources: %s; %s', what, since),
           {tick = now, queued = queued, deep = c.deep, sources = srcs, removed = rm, refuge = ref, last = last, run = run,
            carers = st.out and st.out.cw or nil, locs = st.out and st.out.locs or nil, chain = st.chain}
  end
  local w = st.ws
  local reach, pits = 0, 0
  for _, b in ipairs(w.bodies) do
    if b.bank or b.dig then reach = reach + 1 end
    if b.pit then pits = pits + 1 end
  end
  return true, string.format('water_sources: %d bodies >= %d/7, %d with a bank or a dig, %d with a well spot, %d sources; '
                             .. 'scan %s%s', #w.bodies, w.deep, reach, pits, #srcs, since, sc and ', a new one running' or ''),
         {tick = w.tick, age = now - w.tick, queued = queued, deep = w.deep, boxes = M.first(w.boxes, 12),
          nboxes = #w.boxes, tiles = w.tiles,
          levels = w.levels, bodies = w.bodies, sources = srcs, err = w.err, removed = rm, refuge = ref, last = last,
          run = run, slices = w.slices, reads = w.reads, survey = w.survey, seeds = w.seeds, cut = w.cut, aq = w.aq,
          serr = w.serr, way = M.way_text(M.best_way(w)), wz = ps.wz,
          carers = st.out and st.out.cw or nil, locs = st.out and st.out.locs or nil, chain = st.chain,
          note = 'sources [kind, id, x, y, z, accepted, depth under a well (-1 unknown), burrow]; refuge: its bbox, d = '
                 .. 'its nearest tile to the nearest accepted source (-1 none); bank: stand there and fill or zone the '
                 .. 'water; dig: opening '
                 .. 'the last wall floods the dug tiles (dig from above or behind a floodgate); cavern 1: cavern water, '
                 .. 'never offered (caverns stay sealed); removed: the last dry hospital removal (t, zones, locs, '
                 .. 'n patients, tmax, give = GiveWater jobs then, after = a day later); locs (BUG-056): hospital locations, total / '
                 .. 'with a zone (live) / without (stale: ignored by every count); carers (BUG-054): have, want, idle ones, '
                 .. 'give = citizens giving water, mine = added by the kernel (Orderlies), err = why none was added; pit '
                 .. '(BUG-290): a well spot, the open tile right above the water (stand: the reachable floor beside it); '
                 .. 'last/run (BUG-288): the last finished scan and the running one (slices, at most max); survey/seeds '
                 .. '(BUG-289): the surface levels surveyed and the boxes round what they met; aq (BUG-291): levels with a '
                 .. 'revealed aquifer tile beside the water; way: the best way to water at any distance; wz (BUG-324): the '
                 .. 'Water Source zone dfllm-water the kernel painted last (at = the water tile, up 1 = also the tile above, t, '
                 .. 'ok); wt: a bank\'s water tile'}
end

-- inspect what=hospital (kern routes it here; BUG-106): the audit of the last water run (a game day old at most): the gaps in a
-- fixed vocabulary, each with its counts, then the rooms (beds, tables, traction benches per hospital zone), the doctors
-- (adult citizens outside the squads with each wound care labor on, and with a skill), the supplies the hospital location
-- asks for / holds / needs, the caregivers and the last GiveWater verdict (BUG-104). <= 8 KB; reads nothing itself.
function M.inspect_hospital(K)
  local a = st.audit
  local now = K.now().tick
  if not a then return true, 'hospital: no water run finished yet', {tick = now, queued = 1} end
  local toks = {}
  for i, g in ipairs(a.gaps) do toks[i] = g.tok end
  local msg = #toks == 0 and string.format('hospital: no gaps (%d zones, %d patients)', a.zones, a.patients)
              or string.format('hospital: %d gap%s: %s', #toks, #toks == 1 and '' or 's', table.concat(toks, ', '))
  local d = {tick = a.tick, age = now - a.tick, zones = a.zones, patients = a.patients, gaps = a.gaps, rooms = a.rooms,
             doctors = a.doc, supplies = a.sup, carers = a.carers, give = a.give, outsiders = a.outsiders,
             note = 'gaps: no_zone outside dry no_bed no_table no_traction no_diag no_surgery no_bone no_suture no_dress '
                    .. 'no_splints no_thread no_cloth no_crutches no_plaster no_soap no_buckets supply_unknown no_carers; '
                    .. 'doctors: on = adult citizens outside the squads with the labor on, skilled = of them with a skill '
                    .. '(nil unknown); supplies: want = what the location asks for, have = what it holds, need = the '
                    .. 'game\'s need-more flag, fort = the fort stock (thread, cloth); a nil is a field this DF did not show'}
  return true, trunc(msg, 200), d
end

-- last summary (brief, tests): patients, thirst, wells, hospital/refuge water, buckets
function M.kpi(K) return st.out end

-- published only once the contract has a `water` state key (STATE_SPEC + STATE_OWNERS 'water.*'; BUG-034): hosp = the
-- hospital zones, src = the accepted sources nearest first (plan propose/check: a hospital only within `near` of one)
function M.state(K)
  local o = st.out
  if not o or not (C.STATE_SPEC.opt and C.STATE_SPEC.opt.water) or C.STATE_OWNERS['water.*'] ~= 'water' then
    return {}
  end
  local w = {patients = o.patients, thirst_max = o.thirst_max, hosp_ok = o.hosp_ok, refuge_ok = o.refuge_ok,
             buckets_free = o.buckets_free, hosp = o.hosp, src = o.src or json.array{}, hosp_out = o.hosp_out,
             src_l = o.src_l}
  -- BUG-131: the first blocking hospital zone outside the core (z, its centre, ok 1 = a finished hospital inside exists, pat =
  -- the patients lying in it): status/brief name it and the verb hospital.retire
  local ho = st.hout
  local z = ho and ho.n > 0 and ho.zones[1] or nil
  if z and C.STATE_SPEC.opt.water.opt.hout then
    w.hout = {z = z.id, at = json.array{z.x, z.y, z.z}, ok = ho.fin and 1 or 0, pat = z.pat}
  end
  -- BUG-106: the tokens of the hospital's gaps, while a hospital stands or a patient lies (a fort without either has none
  -- to fix yet); `inspect what=hospital` lists them with their counts
  -- BUG-288/289/290: when the water scan last finished (wst) and the best way to water it found (wsc: bp sites hospital
  -- names it while no accepted water exists)
  local last = pstate(K).ws_last
  if type(last) == 'table' and math.tointeger(last.t) and C.STATE_SPEC.opt.water.opt.wst then w.wst = last.t end
  local wsc = st.ws and M.way_text(M.best_way(st.ws))
  if wsc and C.STATE_SPEC.opt.water.opt.wsc then w.wsc = wsc end
  -- BUG-539/540: the zones bp sites must not build a second hospital beside (a dry memory without water near does not count)
  local hrm = M.hrm_count(K, M.conf(K), st.last, pstate(K), K.now().tick)
  if hrm > 0 and C.STATE_SPEC.opt.water.opt.hrm then w.hrm = hrm end
  local a = st.audit
  if a and #a.gaps > 0 and (a.zones > 0 or a.patients > 0) and C.STATE_SPEC.opt.water.opt.gaps then
    w.gaps = json.array{}
    for i = 1, math.min(8, #a.gaps) do w.gaps[i] = a.gaps[i].tok end
  end
  return {water = w}
end

-- public (BUG-040, readiness): 'well 19098 at 137,77,143 in Kern+' for an accepted source of the last run at that tile,
-- else 'accepted water at x,y,z'
function M.label(K, x, y, z)
  for _, s in ipairs(st.src or {}) do
    if s.wet and s.x == x and s.y == y and s.z == z then
      return string.format('%s %d at %d,%d,%d', s.kind, s.id, x, y, z) .. (s.inn and (' in ' .. s.inn) or '')
    end
  end
  return string.format('accepted water at %d,%d,%d', math.tointeger(x) or -1, math.tointeger(y) or -1,
                       math.tointeger(z) or -1)
end

-- public (BUG-040, seal's burrow audit reports it: a dry cistern's well is no drink for the refuge): the wet wells and all built
-- wells on burrow `name` by the last run (burrow tiles read now); nil before the first run or without that burrow
function M.wet_wells(K, name)
  local b = type(name) == 'string' and st.src and burrow_named(name) or nil
  if not b then return nil end
  local wet, n = 0, 0
  for _, s in ipairs(st.src) do
    if s.kind == 'well' and s.built and on_burrow(b, s.x, s.y, s.z) then
      n = n + 1
      if s.water or (s.water == nil and s.wet) then wet = wet + 1 end      -- BUG-263: the water that is there
    end
  end
  return wet, n
end

-- public (BUG-344, Run 15d Drillchamber y379-y397: DECISION_NEEDED thirst asked 'water near the fort (well), brewing,
-- barrels?' 271 times while 37 citizens died of thirst, 13 of them (no patients) at 75,49-50,142 beside well 18324
-- (76,50,142), which inspect water_sources read wet, their hunger 51,683-94,529): what economy's thirst decision says
-- about the water, by the last run. A thirsty citizen (>= well_thirst, no patient) within 1 tile of an accepted well: that
-- well gives him no water; no accepted water at all; in both cases the recipe (M.recipe: the scan's ways, a Water Source
-- zone from a reachable bank, a well over a pit, a cistern, an aquifer well). Review: the recipe here names no dig at
-- all (M.recipe nodig: digging at water is the player's, only after the PLAYBOOK's water checks), and a well over
-- water below well_min (why 'shallow', no accepted source) a thirsty citizen stands at is named with its depth. Else
-- the nearest accepted water. Returns txt, cmds (command lines); nil before the first run. Report only
function M.drink_fix(K)
  local src = st.src
  if not src then return nil end
  local acc, at, em
  for _, s in ipairs(src) do
    local shallow = s.kind == 'well' and s.below and s.below.why == 'shallow'
    if s.wet and s.emerg then em = em or s elseif s.wet then acc = acc or s end
    if s.kind == 'well' and (s.wet or shallow) and not at then
      for _, t in ipairs(st.thirsty or {}) do
        if t.z == s.z and math.max(math.abs(t.x - s.x), math.abs(t.y - s.y)) <= 1 then at = {s = s, u = t}; break end
      end
    end
  end
  local cmds = json.array{'dfllm cmd inspect what=water_sources'}
  if acc and not at then return 'accepted water: ' .. M.label(K, acc.x, acc.y, acc.z), cmds end
  local c = M.conf(K)
  local head = 'no accepted water'
  if at and at.s.wet then
    head = string.format('citizen %d (thirst %d) stands beside well %d at %d,%d,%d, read wet: it gives no water',
                         at.u.id, at.u.thirst, at.s.id, at.s.x, at.s.y, at.s.z)
  elseif at then
    head = string.format('citizen %d (thirst %d) stands beside well %d at %d,%d,%d: shallow (%d/7 < %d/7), no source',
                         at.u.id, at.u.thirst, at.s.id, at.s.x, at.s.y, at.s.z, at.s.below.flow or 0, c.well_min)
  end
  cmds[#cmds + 1] = 'dfllm bp sites cistern'
  if em then                       -- BUG-425: the one thing that gives a trickle, said first
    head = string.format('EMERGENCY: well %d at %d,%d,%d over only %d/7 is accepted as a slow drink source (water.well_emerg %d, '
                         .. 'normal minimum %d/7); %s', em.id, em.x, em.y, em.z, em.below and em.below.flow or 0, c.well_emerg,
                         c.well_min, head)
  end
  return head .. '; ' .. M.recipe(c, nil, K, true, true), cmds
end

-- public (BUG-449, Run 16d i4 Mazelanterns y403-y408: 5-6 citizens a day stood at the only accepted water, a zone 101 tiles from the
-- core at the map edge, hunger 70-120k, 8 starved; siege's stranded_food offered a farm search): the accepted source (wet well or
-- Water Source zone, last run) within `r` tiles of a position, nearest first: {d, txt} ('zone 17696 at 164,170,137, 9 tiles'); nil when
-- none, or when the fort has an accepted source of its own as near the core (then the water is not what drew them out)
function M.src_near(K, x, y, z, r)
  local best
  for _, s in ipairs(st.src or {}) do
    if s.wet and not s.emerg and s.x then
      local d = math.max(math.abs(s.x - x), math.abs(s.y - y), math.abs(s.z - z))
      if d <= (math.tointeger(r) or 20) and (not best or d < best.d) then best = {d = d, s = s} end
    end
  end
  if not best then return nil end
  local s = best.s
  local inside = s.inn ~= nil                                   -- a source inside Kern+ / Tiefe+ is no reason to walk out
  if inside then return nil end
  return {d = best.d, txt = string.format('%s %s at %d,%d,%d, %d tiles', s.kind, tostring(s.id), s.x, s.y, s.z, best.d)}
end

-- public (BUG-401, Run 16a Mansionlauded and Bachwald: two forts without a drop of reachable water died of thirst, 13 of 16):
-- can the citizens drink anywhere? {known, ok, acc, bank, bodies, partial}: known = a water run and a scan finished; acc =
-- accepted sources (a Water Source zone, a wet well); bank = bodies (not cavern) with a bank the citizens reach (the scan's
-- walk test: ice-covered or walled-off water has none); ok = acc + bank > 0. partial = a body's scan stopped at its read cap.
-- Report only
function M.drink_access(K)
  local ws = st.ws
  if not st.src or not ws then return {known = false, ok = true, acc = 0, bank = 0, bodies = 0} end
  local acc, bank, partial, emerg = 0, 0, 0, 0
  for _, s in ipairs(st.src) do
    if s.wet and s.emerg then emerg = emerg + 1 elseif s.wet then acc = acc + 1 end       -- BUG-425: a slow emergency well is no source
  end
  local bd, bat                                 -- BUG-446: the nearest body with a bank (its distance, its water tile)
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern ~= 1 and b.bank then
      bank = bank + 1
      if not bd or (b.nd or b.d) < bd then bd, bat = b.nd or b.d, b.at end
    end
    if b.partial == 1 then partial = partial + 1 end
  end
  -- BUG-423/424: `near` = the water nearest to the fort or a citizen (b.at is that tile, b.nd its distance) of the bodies without
  -- a bank, with `rock` 1 when no bank exists within ws_dig walls either (the brook lies behind rock)
  local near
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern ~= 1 and not b.bank and (not near or (b.nd or b.d) < (near.nd or near.d)) then near = b end
  end
  -- BUG-446 (Run 16b i2 Roadvises: a pond 72 tiles off was 'reachable water', drink 0 days and no word): `far` = no accepted source and
  -- the nearest bank farther than drink_far tiles (bd, bat = that body's nearest water tile); economy's no_water treats it as dry once
  -- the drink is short and no plant brews
  local cf = M.conf(K)
  local far = acc == 0 and bd ~= nil and cf.drink_far > 0 and bd > cf.drink_far
  return {known = true, ok = acc + bank > 0, acc = acc, bank = bank, bodies = #(ws.bodies or {}), partial = partial, emerg = emerg,
          near = near and {near.at[1], near.at[2], near.at[3]} or nil, nd = near and (near.nd or near.d) or nil,
          far = far or nil, far_d = cf.drink_far_d, bd = bd, bat = bat and {bat[1], bat[2], bat[3]} or nil}
end

-- public (BUG-036, readiness): the hospital zones outside Kern+ and the refuge by the last run: {n, total, zones = {{id,
-- loc, x, y, z (the zone's centre), tiles (outside), of (tiles looked at, <= HOSP_TILES)}}, kern, refuge}; n 0 before the
-- first run
function M.hospital_out(K)
  return st.hout or {n = 0, total = 0, zones = {}}
end

-- verb hospital.retire {zone, approve?} (BUG-131, Run 14: an old zone outside the core kept R0 hospital_out red the whole
-- run): the zones screen's remove (act.hospital_remove) for ONE hospital zone outside Kern+/Tiefe+ of the last water run.
-- PEACE only (contract); refused while a patient lies in it (read now, approve or not) and without a finished hospital
-- inside the core (ho.fin) unless the player said approve:true. The location stays (no script can delete it): with no
-- zone left every count ignores it (BUG-056) and care moves its doctors' posts to the live hospital (BUG-077).
M.verbs['hospital.retire'] = function(K, args, cmd)
  local id = math.tointeger(args.zone)
  if not id then return false, 'hospital.retire: zone must be a zone id' end
  local ho = st.hout
  if not ho or not st.out then return false, 'hospital.retire: no water run finished yet; try again in a game day' end
  local z, h
  for _, list in ipairs({ho.zones or {}, ho.ign or {}}) do
    for _, x in ipairs(list) do if x.id == id then z = x end end
  end
  for _, x in ipairs(st.hz or {}) do if x.id == id then h = x end end
  if not h then return false, string.format('hospital.retire: no hospital zone %d (last water run)', id) end
  local at = string.format('%d,%d,%d', (h.x1 + h.x2) // 2, (h.y1 + h.y2) // 2, h.z)
  local core = string.format('%s/%s', tostring(ho.kern or 'Kern+'), tostring(ho.refuge or 'Tiefe+'))
  if not z then return false, string.format('hospital.retire: zone %d at %s lies inside %s: it stays', id, at, core) end
  local pts = {}
  local cu = K.census.u
  for _, uid in ipairs(type(cu) == 'table' and cu.ids or {}) do
    local u = df.unit.find(uid)
    if u and WHO.citizen(u) and patient(u) then
      local x, y, zz = dfhack.units.getPosition(u)
      pts[#pts + 1] = {x = x, y = y, z = zz}
    end
  end
  local n = M.zone_patients(pts, h)
  if n > 0 then
    return false, string.format('hospital.retire: zone %d at %s: %d patient%s in it: it stays until %s', id, at, n,
                                n == 1 and ' lies' or 's lie', n == 1 and 'he is up or moved' or 'they are up or moved')
  end
  local approve = args.approve == true
  if not ho.fin and not approve then
    return false, string.format('hospital.retire: zone %d at %s: no finished hospital inside %s (a zone with a bed): '
                                .. "build it first, or approve:true on the player's word", id, at, core)
  end
  local ok, err = K.act.hospital_remove(id)
  if not ok then return false, string.format('hospital.retire: zone %d at %s: %s', id, at, tostring(err)) end
  local left, keep_hz = 0, {}
  for _, x in ipairs(st.hz or {}) do
    if x.id ~= id then
      keep_hz[#keep_hz + 1] = x
      if x.loc == h.loc then left = left + 1 end
    end
  end
  st.hz = keep_hz
  for _, key in ipairs({'zones', 'ign'}) do
    local keep = {}
    for _, x in ipairs(ho[key] or {}) do if x.id ~= id then keep[#keep + 1] = x end end
    ho[key] = keep
  end
  ho.n, ho.total = #ho.zones, math.max(0, (ho.total or 1) - 1)
  st.out.hosp_out = ho.n
  local loc = math.tointeger(h.loc) or -1
  local msg = string.format('retired hospital zone %d at %s (location %d, zones screen remove%s); %s', id, at, loc,
                            approve and ', approved by the player' or '',
                            left == 0 and 'the location has no zone left: every count ignores it (BUG-056), its '
                                          .. "doctors' posts move to the live hospital (BUG-077)"
                            or string.format('location %d keeps %d zone%s', loc, left, left == 1 and '' or 's'))
  K.log('info', 'water: %s; %d zone(s) outside %s still block', msg, ho.n, core)
  return true, msg, {zone = id, at = json.array{(h.x1 + h.x2) // 2, (h.y1 + h.y2) // 2, h.z}, loc = loc, left = left,
                     approve = approve and 1 or 0, why = z.why, blocking = ho.n}
end

-- verb well.retire {id, approve?} (BUG-541, Run 16b i2 y386/y390, Run 16d i4 y404: the GiveWater carriers stood 26-28 days at a
-- DRY well beside the hospital, the patients died): the building screen's remove for ONE built well that has no water below it
-- (the last water run's sources: `wet` false, not an emergency well). A well of a cistern room of the manifest is meant to fill:
-- it goes only on approve:true (the player's word). Wet wells are never touched. Any mode (a dying patient does not wait).
M.verbs['well.retire'] = function(K, args, cmd)
  local id = math.tointeger(args.id)
  if not id then return false, 'well.retire: id must be a well id' end
  if not st.last or not st.out then return false, 'well.retire: no water run finished yet; try again in a game day' end
  local w
  for _, s in ipairs(st.last.sources) do if s.kind == 'well' and s.id == id then w = s end end
  if not w then return false, string.format('well.retire: no well %d in the last water run (inspect what=water_sources lists them)', id) end
  local at = string.format('%d,%d,%d', w.x, w.y, w.z)
  if w.wet or w.loop or w.water then
    return false, string.format('well.retire: well %d at %s has water below it%s: it stays', id, at,
                                w.loop and ' (a loop well holds its own pond store)' or '')
  end
  if w.built == false then
    return false, string.format('well.retire: well %d at %s is not built yet: cancel its project instead', id, at)
  end
  local approve = args.approve == true
  if not approve then
    for _, rm in ipairs(K.manifest().rooms or {}) do
      local b = rm.bbox
      if rm.tpl == 'cistern' and type(b) == 'table' and #b >= 6 and w.z == b[3] and w.x >= b[1] and w.x <= b[4]
         and w.y >= b[2] and w.y <= b[5] then
        return false, string.format("well.retire: well %d at %s belongs to the cistern room %s (a cistern's well fills with its pond): "
                                    .. "approve:true on the player's word", id, at, tostring(rm.id))
      end
    end
  end
  if not M.can('well_remove') then return false, 'well.retire: this kernel build has no well_remove act' end
  local ok, err = K.act.well_remove(id)
  if not ok then return false, string.format('well.retire: well %d at %s: %s', id, at, tostring(err)) end
  local out = {}
  for _, s in ipairs(st.last.sources) do if not (s.kind == 'well' and s.id == id) then out[#out + 1] = s end end
  st.last.sources = out
  local msg = string.format('retired the dry well %d at %s (building screen remove%s): the carriers fill at the accepted water',
                            id, at, approve and ', approved by the player' or '')
  K.log('warn', 'water: %s', msg)
  return true, trunc(msg, 400), {well = id, at = json.array{w.x, w.y, w.z}, approve = approve and 1 or 0}
end

return M
