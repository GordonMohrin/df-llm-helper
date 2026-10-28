-- reflex (FR-36/49/51/52/53/58): the arrival lockdown and the interrupt channel, inside the kernel, fail-open.
-- Run 9 (14.10.2026): an army with two cave dragons walked in over lowered drawbridges and 39 of 48 citizens died
-- within 76 s of real time at ~400 ticks/s. SIEGE_START/INVASION were digest events (the first wake was BREACH, with
-- the enemy inside), the seal "failed closed" without a fortcore manifest (sealed 0 ticks), and every actuator was
-- driven by the operator's polling loop (tools/run_guard.py, run_rescue.py), which could not keep up.
--
-- Arrival lockdown (no LLM in the loop). Triggers: an arrival announcement (a popup the arbiter hands over, or a
-- report: "A vile force of darkness has arrived", "ambush", "snatcher", a beast that "has come"; AMBUSH_*,
-- BEAST_AMBUSH, MEGABEAST/WEREBEAST_ARRIVAL), INVASION, or the first armed hostile in sight (a visible invader, a
-- great danger in reach). In the same step, without waiting for a sighting:
--   clock  the arbiter switches timestream off and holds the vanilla FPS cap at the siege cap (it asks M.holding)
--   gates  gate wants every linked drawbridge up: manifest outer/inner bridges and every lever-linked bridge outside
--          the manifest, so a fort without fortcore is covered (same single-pending-pull invariant)
--   doors  the fort's entrance doors are forbidden through act.door_forbid (the door sheet's forbid toggle): a built
--          door on or next to a revealed open-sky tile, and (BUG-012, Run 9: "0 entrances" with a door one tile behind
--          the east stair) the doors seal's entrance check finds on each opening's route toward the citizens and a few
--          steps inside it (seal.entrance_doors; a fresh check is asked for, its doors are added when it lands). Doors
--          the player had forbidden, or opened again during the lockdown, are left alone; the openings without a door
--          are named ("partial lockdown: ... has no door"). A door waits while a citizen is on its outside side
--          (seal.door_outside; the civ alert calls him in), at most ALERT_AFTER ticks, not at all with a visible
--          hostile within DOOR_NEAR of it: nobody is locked out with the army ("1 waiting for 2 citizens outside");
--          BUG-013: the wait ends ALERT_AFTER ticks after the civ alert began to call them in
--          BUG-015 (the entrance door 16970 lost its forbidden flag within one frame, ARRIVAL still said "doors 1
--          forbidden"): every forbidden door is read back on the next pass; a door whose flag fell back leaves the
--          count, is named as a partial lockdown entry ("door 16970 (74,70,117) refused (flag reset)") and
--          LOCKDOWN_PARTIAL (A) says so; it is tried once more (forbidden + closed) when the units or items on and
--          next to its tile changed, at the latest DOOR_RETRY ticks later
--   alert  siege sounds the civ alert (it asks M.holding) once no lever pull of the lockdown is pending (gate.pulls:
--          every wanted bridge up, or none left to pull), at the deadline (BUG-013: ALERT_LAT x the last measured
--          lever latency, ALERT_AFTER..ALERT_MAX ticks, ALERT_UNKNOWN before the first measurement), or at once when
--          a hostile is near a citizen outside Kern+ or inside: the alert keeps civilians inside its burrows, and
--          live L3 and Run 9 (677bc3e) lost lever pulls to it (GATE_FAIL no_worker; 1-3 of 4 bridges up). Should it
--          sound with pulls pending, gate lists seal's lever burrow next to the main one (gate.rooms). siege owns
--          the alert state and seal picks the burrow (Kern+, else the interior Innen+); the text says what
--          really holds ("alert: Innen+ (REFUGE_FAIL ...)", "alert: none (...)"), never what was asked (BUG-011),
--          and so do the gates ("gates: 2 of 4 up, 2 pulls blocked (levers outside the alert burrow)")
--   recall Run 11 (siege 8, y441: 16 citizens were outside Kern+ when the arrival came, 7 still outside at the breach):
--          while citizens (soldiers excluded) stand outside Kern+ and the refuge, the alert sounds at once instead of
--          after the pulls (alert_due 'citizens outside'): the alert lists seal's lever burrow while a pull is pending
--          (gate.rooms, BUG-013, live-confirmed), so the pulls go on under it. The doors then wait for those citizens up
--          to RECALL_MAX ticks after the alert sounded (ALERT_AFTER when it did not really sound: no burrow, they are not
--          called), never with a visible hostile within DOOR_NEAR of the door. The recall (st.hold.rc) is reported:
--          kern.log at its start (how many, the ETA), at SIEGE/BREACH while some are still out, RECALL (B) when all
--          came in (ticks), at RECALL_MAX with the ones still out ('late') and at the lockdown's end ('end'); the
--          ARRIVAL/LOCKDOWN text says '16 citizens outside Kern+ called in' / '7 of 16 citizens still outside ...'
--          BUG-035 (Run 11 siege 9: 'recall: 9 of 5 still outside', the same two citizens never came in, in siege 9 and
--          in the ambush after it, the doors waited 2,400 ticks for one of them): the recall measures arrival in the
--          burrows the alert really confines to (its own, Kern+/Tiefe+/Innen+ it lists; sense.recount counts against
--          them) and follows the citizens it called by id: those out since are counted apart ('+4 more out since'), a
--          switch of the alert's burrow re-targets it (kern.log). Every citizen still out is diagnosed (read-only:
--          caged, carried, mood, down, patient, sleep, gate's lever puller, his own burrow, walking, a job, idle; seal's
--          path check RECALL_PATH ticks after the alert for one who could come: a way only through doors this lockdown
--          forbade opens them again for him, a door the player forbade or another walk group is reported). One who
--          cannot come holds no door (seal.door_outside skip) and RECALL stuck says so once per lockdown; gate's
--          pullers stay by their levers on purpose and never keep the recall open
-- then ARRIVAL (A) carries what was done and the text. A popup is dismissed by the arbiter only after this returned
-- (FR-36). The lockdown holds until threat is 0 (no visible invader, great danger in reach or hostile inside, the
-- threat scan not armed, ARM ticks after the last trigger) for hold_quiet_days game days; then the doors it forbade
-- open again, clock and alert follow the mode, and gate lowers the bridges it raised (peace_gates D-14 down) or
-- keeps them up (D-14 up). LOCKDOWN_END (B).
-- Run 11 (Kilrudrabed site98 y439: ALERT and an arrival:ambush lockdown for 45 days, clock 30 t/s, 6 doors forbidden,
-- idle 68 %, for ONE invader, an ELK_BIRD mount left behind at the map edge 100+ tiles from everybody): the lockdown
-- also expires without an approach. In PEACE/ALERT visible invaders do not stop the quiet clock while every one of them
-- stays beyond lockdown_near (config/reflex.json, 40; 0 = off) tiles of every citizen outside Kern+ (sense dc) and of
-- every entrance (gate.points, the lockdown's doors, seal.entrances); one closer, inside Kern+, of unknown distance or
-- not listed restarts it (far_scan, far_now). LOCKDOWN_END then says `cause` far and names the hostiles in sight; the
-- invaders among them become expired far (st.far, reflex.far_ids): threat counts them for nothing, so ALERT ends too,
-- the sighting and INTRUDER skip them, and an ack timeout applies no default for a far unit. One that comes within
-- lockdown_near leaves the list at once and counts again: it re-arms the lockdown (ARRIVAL 'came within N tiles').
-- sense lists an invader the raws call an animal (an = 1) as a wild danger: the predator rules, never an arrival.
-- BUG-065 (Run 14: a gremlin in the caves, z91, the fort's walk group, kept the Kern+ lockdown on for months; every
-- project outside Kern+ stalled, civ_alert cleared by hand came back within 15 s because the held lockdown sounds it
-- level-triggered, the brief said 'threat 0 vis'): a hostile near a citizen kept the quiet clock off for ever and the
-- lockdown had no clock of its own. A lone thief still starts a lockdown (Gordon), but now:
--   * the state names the cause (alarm.by: unit, race, kind, position, tiles to the nearest citizen outside Kern+ and to
--     the nearest entrance, harmless or not) and why the quiet clock does not run (alarm.qw: near, inside, great, recent,
--     armed, stale, run), the lockdown's age and its limit (alarm.age, alarm.lim);
--   * confine.max_days (config/reflex.json, 10 game days, 0 = off) ends the lockdown by itself (LOCKDOWN_END cause
--     limit) in PEACE/ALERT unless a dangerous hostile is within the near radius (inside Kern+, or lockdown_near of a
--     citizen outside it or of an entrance, or of unknown distance) or a trigger came in the last ARM ticks. Harmless =
--     no great danger, undead, building destroyer, large predator, trap avoider or flier, and a body size up to
--     confine.harmless_size (or a race in confine.harmless_races), and at most confine.lone_max of them in the picture.
--     The harmless ones left near are cleared (st.far.hl): they count for nothing (threat, sighting, INTRUDER, the ack
--     default) until another hostile is in sight or one comes inside Kern+, so the civ alert, the clock clamp and the
--     doors do not come back for the same intruder; the clock returns to the mode's own cap with the release;
--   * a harmless intruder that held the lockdown for confine.offer_days gets a sortie offer (DECISION_NEEDED
--     intruder_sortie: the exact squad.sortie command, once per unit and cause; a repeat needs another unit, at the earliest after offer_days); a dangerous one past the limit is reported
--     the same way (the lockdown stays: the sortie is the way out);
--   * a mood dwarf or a patient behind the sounding alert over confine.need_thirst / need_hunger is reported
--     (DECISION_NEEDED confined_need); with nothing dangerous near the lockdown ends for him (cause need), else the
--     siege module's relax path (STRANDED) is the existing rescue and the lockdown stays.
--
-- Interrupt channel (FR-53). INTERRUPTS (contract): ARRIVAL; INTRUDER (a visible invader, undead or great danger on
-- the citizens' walkable group); PREDATOR (a visible wild danger on a roofed tile of that group); DEATHS_3PLUS (care);
-- NO_DEPOT (merchants need a trade depot; once per caravan visit, BUG-008). Each goes to <save>/alarm.txt at once (a DEFCON line, then the last
-- interrupts), `dfllm wait --until-interrupt` returns on it, and verb `ack` records the operator's ack. An interrupt
-- still unacked after ack_timeout_s (real seconds, measured on K.now().ms, which also runs while paused) gets its type's lockdown default (config/reflex.json `defaults`)
-- from the kernel itself, and LOCKDOWN (A) says so. state alarm = {defcon 1 (worst) .. 5, unacked, last, ack, lock,
-- why, eta}. ETA (FR-58): nearest visible invader to the nearest entrance (Chebyshev tiles x ETA_TILE ticks).
-- Reads: census (K.census.h/u), building vectors (doors, via gate the levers), snapshot.far/outside_near for tiles.
local fio = require('dfllm.io')
local geom = require('dfllm.util.geom')
local CAD = require('dfllm.util.cadence')   -- BUG-008: NO_DEPOT without a readable caravan

local M = {name = 'reflex', every = {ticks = 10}, critical = true, verbs = {},
           reports = {AMBUSH_AMBUSHER = true, AMBUSH_SNATCHER = true, BEAST_AMBUSH = true, MEGABEAST_ARRIVAL = true,
                      WEREBEAST_ARRIVAL = true, MERCHANTS_NEED_DEPOT = true}}

M.ACTIONS = {'clock', 'gates', 'doors', 'alert'}   -- the closed action vocabulary, in the order they are issued
M.CFG = {
  hold_quiet_days = 2,     -- game days of threat 0 before a lockdown ends (the clock clamp with it)
  ack_timeout_s = 60,      -- real seconds an interrupt may stand unacked before its default applies
  -- Run 10 y421 (four lockdowns in ten days for animals at the map edge 60-120 tiles away): a wild danger counts
  -- for PREDATOR only inside Kern+ / past B1 or within this many tiles of a citizen outside Kern+ (0 = no limit)
  predator_near = 40,
  -- Run 11: a visible hostile within this many tiles of a citizen outside Kern+ or of an entrance is an approach; a
  -- lockdown expires after hold_quiet_days without one, invaders visible farther away included (0 = off)
  lockdown_near = 40,
  -- BUG-065: the confinement limit and the harmless-intruder picture (see the header)
  confine = {max_days = 10, harmless_size = 20000, lone_max = 2, offer_days = 1, need_thirst = 40000, need_hunger = 60000},
  defaults = {ARRIVAL = {'clock', 'gates', 'doors', 'alert'}, INTRUDER = {'clock', 'gates', 'doors', 'alert'},
              PREDATOR = {'clock', 'alert'}, DEATHS_3PLUS = {'clock'}, NO_DEPOT = {}},
  -- BUG-108 (Run 14 note 88): interrupt types whose cause lies inside the fort (patients, moods, a curse, a tantrum).
  -- Unacked at threat 0 they only wake the player: no default (no clock clamp, no civ alert); with a visible
  -- hostile, or no fresh reading, their default applies as before. {} = the old rule for every type.
  inner = {'DEATHS_3PLUS'},
}
M.ARM = 2400               -- ticks after the last trigger before the quiet clock may start (threat's armed window)
M.KEEP = 20                -- interrupts kept for alarm.txt and the ack bookkeeping
M.DOOR_EVERY = 2400        -- ticks between entrance-door scans (a trigger without a fresh list scans at once)
M.DOOR_MAX = 400           -- doors looked at per scan
M.REARM = 1200             -- INTRUDER/PREDATOR again only after this many ticks without one
M.ETA_TILE = 6             -- ticks per tile for the ETA (dwarves and goblins walk ~9, fast beasts less)
M.FRESH = 200              -- census.h older than this is unknown (never quiet, no sighting)
-- BUG-013 (Run 9 forced arrival on 677bc3e: the alert sounded 6 s after the popup, the pulls took 9-16 s real, 526-801
-- ticks): the civ alert waits for the lockdown's lever pulls ALERT_LAT x the last measured lever latency (gate lat_t),
-- at least ALERT_AFTER and at most ALERT_MAX ticks; ALERT_UNKNOWN before the first measurement (gate's DEADLINE: an
-- 'up' not reached by then is a GATE_FAIL anyway). A door waits for the citizens outside at most ALERT_AFTER ticks
-- after the alert began to call them in.
M.ALERT_AFTER = 450
M.ALERT_MAX = 1500
M.ALERT_LAT = 2
M.ALERT_UNKNOWN = 900
M.ALERT_NEAR = 30          -- ... and not at all for a hostile this close to a citizen outside Kern+
-- Run 11 (siege 8): citizens outside Kern+ are called in at once; the doors wait for them up to RECALL_MAX ticks after
-- the alert sounded (a dwarf walks ~9 ticks a tile: 2,400 ticks bring one home from ~250 tiles), looked at every
-- RECALL_POLL ticks
M.RECALL_MAX = 2400
M.RECALL_POLL = 25
M.RECALL_IDS = 40          -- citizen ids a recall keeps (BUG-035: census.u.away_ids holds 40, outside_ids 20)
-- popup / report text -> kind (lower case plain markers)
M.TEXT = {{'vile force of darkness', 'siege'}, {'an ambush', 'ambush'}, {'snatcher', 'snatcher'},
          {'has come', 'beast'}, {'need a trade depot', 'no_depot'}}
local REPORT_KIND = {AMBUSH_AMBUSHER = 'ambush', BEAST_AMBUSH = 'ambush', AMBUSH_SNATCHER = 'snatcher',
                     MEGABEAST_ARRIVAL = 'beast', WEREBEAST_ARRIVAL = 'beast', MERCHANTS_NEED_DEPOT = 'no_depot'}
local ARMY = {siege = true, invasion = true, beast = true, invader = true}   -- DEFCON 2 kinds

local st      -- persisted m.reflex: {v, hold = {why, kinds, acts, since, last, qs, rc (Run 11: the recall {t, n, ids, eta,
              --   called, burrow, left, late, done})}|nil, doors = {ids}, ack = {n, wall},
              --   irq = {{n, type, tick, wall, ms, msg, done (1 default applied, 2 none: its unit far), u (unit)}},
              --   vfy = {{id, t, try, pos}} (forbidden, not read back yet; BUG-015), ref = {{id, t, try, pos, sig, items,
              --   units}} (refused: the flag fell back), prec, far = {t, ids} (Run 11: expired far)}
local rt      -- runtime: door cache, sighting/intruder bookkeeping, alarm.txt signature, eta; Run 11: fset (st.far as a
              --   set), ap (per listed hostile: near/unknown/far, dc, de, d), ftick (the census ap belongs to), appr
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.reflex', st); dirty = false end end

---------------------------------------------------------------- config (config/reflex.json via K.cfg.reflex)
local function cfg(K)
  local c = {hold_quiet_days = M.CFG.hold_quiet_days, ack_timeout_s = M.CFG.ack_timeout_s,
             predator_near = M.CFG.predator_near, lockdown_near = M.CFG.lockdown_near, defaults = {}, inner = {}}
  for t, acts in pairs(M.CFG.defaults) do c.defaults[t] = acts end
  for _, t in ipairs(M.CFG.inner) do c.inner[t] = true end
  local r = type(K.cfg.reflex) == 'table' and K.cfg.reflex or {}
  if type(r.inner) == 'table' then                       -- BUG-108: a list of interrupt types; a bad entry keeps the default
    local ok, l = true, {}
    for _, t in ipairs(r.inner) do
      if type(t) == 'string' and M.CFG.defaults[t] then l[t] = true else ok = false end
    end
    if ok then c.inner = l end
  end
  local q, a = int(r.hold_quiet_days), int(r.ack_timeout_s)
  if q and q >= 0 and q <= 30 then c.hold_quiet_days = q end
  if a and a >= 5 and a <= 3600 then c.ack_timeout_s = a end
  local pn, ln = int(r.predator_near), int(r.lockdown_near)
  if pn and pn >= 0 and pn <= 400 then c.predator_near = pn end
  if ln and ln >= 0 and ln <= 400 then c.lockdown_near = ln end
  c.confine = {harmless_races = {}}                     -- BUG-065
  for k, v in pairs(M.CFG.confine) do c.confine[k] = v end
  local cf = type(r.confine) == 'table' and r.confine or {}
  for k, lim in pairs({max_days = {0, 365}, harmless_size = {0, 5000000}, lone_max = {1, 10}, offer_days = {0, 365},
                       need_thirst = {10000, 75000}, need_hunger = {10000, 100000}}) do
    local v = int(cf[k])
    if v and v >= lim[1] and v <= lim[2] then c.confine[k] = v end
  end
  for _, v in ipairs(type(cf.harmless_races) == 'table' and cf.harmless_races or {}) do
    if type(v) == 'string' and v:match('^[A-Z][A-Z0-9_]*$') and #v <= 40 and #c.confine.harmless_races < 16 then
      c.confine.harmless_races[#c.confine.harmless_races + 1] = v
    end
  end
  local valid = {}
  for _, x in ipairs(M.ACTIONS) do valid[x] = true end
  for t, acts in pairs(type(r.defaults) == 'table' and r.defaults or {}) do
    if M.CFG.defaults[t] and type(acts) == 'table' then
      local ok, l = true, {}
      for _, x in ipairs(acts) do if valid[x] then l[#l + 1] = x else ok = false end end
      if ok then c.defaults[t] = l end
    end
  end
  return c
end
M.cfg = cfg

function M.kind_of(text)
  local low = tostring(text or ''):lower()
  for _, m in ipairs(M.TEXT) do
    if low:find(m[1], 1, true) then return m[2] end
  end
end

M.ALERT_TEXT = 90         -- bytes of the alert's answer in the text (the whole of it is d.alert)
M.MSG_MAX = 200           -- an event text is cut there (kern), and so is alarm.txt's copy

-- prefix .. parts (', ' between) .. tail within MSG_MAX: a part that does not fit is left out whole (its numbers are
-- in d), the tail (the announcement) is cut; Run 9's ARRIVAL lost its alert and doors to the cut
local function compose(prefix, parts, tail)
  local s, first = prefix, true
  for _, p in ipairs(parts) do
    local add = (first and '' or ', ') .. p
    if #s + #add <= M.MSG_MAX then s, first = s .. add, false end
  end
  if tail and #s < M.MSG_MAX then s = s .. tail:sub(1, M.MSG_MAX - #s) end
  return s
end

---------------------------------------------------------------- the entrance doors
local function door_pos(b)
  local ok, x, y, z = pcall(function() return b.centerx or b.x1, b.centery or b.y1, b.z end)
  if ok and int(x) and int(y) and int(z) then return {int(x), int(y), int(z)} end
end

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or r == true             -- unknown (no stage API): count it
end

-- built doors next to a revealed open-sky tile: {{id, pos}}; nil when the tile test is unavailable (no snapshot)
local function scan_doors(K, now)
  local cand, pts = {}, {}
  local ok = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.DOOR) do
      if #cand >= M.DOOR_MAX then break end
      local p = built(b) and door_pos(b)
      if p then cand[#cand + 1] = {id = b.id, pos = p}; pts[#pts + 1] = p end
    end
  end)
  if not ok then K.log('warn', 'reflex: door scan failed') end
  local list = {}
  if #cand > 0 then
    local okc, out = K.call('snapshot', 'outside_near', pts, 1)
    if okc and type(out) == 'table' then
      for i, c in ipairs(cand) do if out[i] == 1 then list[#list + 1] = c end end
    else list = nil end                   -- no tile test: forbid nothing (forbidding every door would lock rooms)
  end
  rt.doors = {tick = now, list = list}
  return list
end

local function entrance_doors(K, now, force)
  local d = rt.doors
  if not force and d and now >= d.tick and now - d.tick < M.DOOR_EVERY then return d.list end
  return scan_doors(K, now)
end

-- BUG-012: seal's entrance check (doors on the routes from the openings toward the citizens, openings without a
-- door); `refresh` asks it for a fresh check. Returns the export, or nil and 'pending' (no check yet) | 'none' (no
-- seal module)
local function seal_doors(K, refresh)
  local ok, x = K.call('seal', 'entrance_doors', refresh == true)
  if not ok then return nil, 'none' end
  if type(x) ~= 'table' then return nil, 'pending' end
  return x
end

M.OPEN_SHOWN = 2           -- openings without a door named in the text (the rest counted)
M.DOOR_NEAR = 15           -- a visible hostile this close to a waiting door forbids it at once
M.DOOR_POLL = 20           -- ticks between two looks at the doors still waiting for citizens outside
-- BUG-015: a refused door (its forbidden flag fell back before the next pass) is tried once more, with `closed`, once
-- the visible units on or next to its tile or the items on it changed, at the latest DOOR_RETRY ticks after the refusal
M.DOOR_RETRY = 1200
M.REF_SHOWN = 2            -- refused doors named in the text (the rest counted)

-- citizens on the outside side of each door (seal.door_outside: open sky of its walk group, the porch of its opening,
-- the doorway); without seal, sense's citizens outside Kern+ hold every door. Returns {[id] = n}, distinct n.
-- BUG-035: the citizens the recall found unable to come (rt.nohold: lying, caged, held at a lever, no way in) hold none
local function door_outside(K, list)
  local ids = {}
  for _, d in ipairs(list) do ids[#ids + 1] = d.id end
  local ok, per, n = K.call('seal', 'door_outside', ids, rt.nohold or {})
  if ok and type(per) == 'table' then return per, int(n) or 0 end
  local cu = K.census.u
  local o = type(cu) == 'table' and int(cu.outside) or 0
  if o and o > 0 and rt.nohold then
    for _, id in ipairs(type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
      if rt.nohold[id] then o = o - 1 end
    end
  end
  local r = {}
  if o and o > 0 then for _, id in ipairs(ids) do r[id] = o end else o = 0 end
  return r, o
end

-- BUG-035: a door the recall opened again for citizens whose only way in crosses it (rt.need) waits while one of them
-- is still out (rt.rout); returns how many
local function needers(id)
  local nd = rt.need and rt.need[id]
  if not nd then return 0 end
  local c = 0
  for uid in pairs(nd) do if rt.rout and rt.rout[uid] then c = c + 1 end end
  if c == 0 then rt.need[id] = nil end
  return c
end

-- a visible hostile within DOOR_NEAR of p (a fresh census only)
local function hostile_near(K, p, now)
  local h = K.census.h
  if type(h) ~= 'table' or now - (h.tick or -1e9) > M.FRESH then return false end
  for _, e in ipairs(h.list or {}) do
    if geom.dist(e, {x = p[1], y = p[2], z = p[3]}) <= M.DOOR_NEAR then return true end
  end
  return false
end

-- BUG-013: the doors stop waiting for the citizens outside ALERT_AFTER ticks after the civ alert began to call them in
-- (the alert itself may wait for the lever pulls up to ALERT_MAX); a lockdown without the alert action counts from
-- the moment it first wanted the doors. Run 11 (siege 8: 16 citizens outside at the arrival): a recall (the alert
-- sounded with citizens outside and really called them: a burrow was listed) holds them open RECALL_MAX ticks
local function doors_late(h, now)
  if not h then return true end
  local t0, wait = h.doors_at, M.ALERT_AFTER
  if h.acts.alert then
    t0 = h.alert_on and (h.alert_t or h.doors_at) or nil
    if h.rc and h.rc.called then wait = M.RECALL_MAX end
  end
  return t0 ~= nil and now - t0 >= wait
end

-- BUG-015: what stands on and next to a door's tile: the visible units within one tile on its level
-- (snapshot.units_at) and the items on the ground of the tile itself (snapshot.items_at; revealed tiles only). Returns a signature (a retry waits for it
-- to change), the items, the units on or next to the tile and the units on the tile itself.
local function tile_sig(K, p)
  local us, on = {}, 0
  local oku, ul = K.call('snapshot', 'units_at', p[1] - 1, p[2] - 1, p[1] + 1, p[2] + 1, p[3])
  if oku and type(ul) == 'table' then
    for _, u in ipairs(ul) do
      us[#us + 1] = string.format('%d@%d,%d', u[1], u[2], u[3])
      if u[2] == p[1] and u[3] == p[2] then on = on + 1 end
    end
  end
  local its = {}
  local ok, l = K.call('snapshot', 'items_at', p[1], p[2], p[1], p[2], p[3])
  if ok and type(l) == 'table' then
    for _, it in ipairs(l) do its[#its + 1] = tostring(it[1]) end
  end
  return table.concat(us, ' ') .. '|' .. table.concat(its, ' '), #its, #us, on
end

local function find_ref(id)
  for i, r in ipairs(st.ref) do if r.id == id then return r, i end end
end

local function drop_door(id)
  for i = #st.doors, 1, -1 do if st.doors[i] == id then table.remove(st.doors, i) end end
end

-- BUG-015: a refused door's one retry is due once what stands on or next to its tile changed, at the latest
-- DOOR_RETRY ticks after the refusal
local function retry_due(K, r, now)
  if r.try ~= 1 then return false end
  if now - r.t >= M.DOOR_RETRY or now < r.t then return true end
  return (tile_sig(K, r.pos)) ~= r.sig
end

-- the refused doors of this lockdown that are not being tried again (not in st.doors), in refusal order
local function refused_now()
  local mine, l = {}, {}
  for _, id in ipairs(st.doors) do mine[id] = true end
  for _, r in ipairs(st.ref) do if not mine[r.id] then l[#l + 1] = r end end
  return l
end

local function ref_text(r)
  return string.format('door %d (%d,%d,%d) refused (flag reset)', r.id, r.pos[1], r.pos[2], r.pos[3])
end

-- forbid the entrance doors not forbidden yet: the open-sky scan and seal's entrance doors. A door forbidden by
-- us stays ours (never forbidden twice, never again once the player opened it); a door the player forbade is left
-- alone and never opened. Safety (citizens shut out): a door waits while a citizen is on its outside side (the civ
-- alert calls them in meanwhile) and is forbidden once nobody is left there, at once with a visible hostile within
-- DOOR_NEAR of it, and in any case once doors_late (ALERT_AFTER after the alert sounded). BUG-015: a door whose flag
-- fell back (verify_doors) is a partial lockdown entry, tried once more (forbidden + closed) when retry_due. Returns
-- the text part and the number newly forbidden; rt.wait = the doors still waiting, rt.wait_out = the citizens they
-- wait for.
local function forbid_doors(K, now, refresh)
  local near = entrance_doors(K, now, refresh)
  local sd, sstate = seal_doors(K, refresh)
  rt.seal_tick = sd and sd.tick or nil
  rt.wait, rt.wait_out, rt.wait_t = {}, 0, now
  if near == nil and sd == nil then
    return sstate == 'pending' and 'doors: no tile test, entrance check pending' or 'doors: no tile test', 0
  end
  local cand, seen = {}, {}
  local reo = {}                                             -- BUG-035: the doors opened again for recalled citizens
  for _, d in pairs(rt.reo or {}) do reo[#reo + 1] = d end
  table.sort(reo, function(a, b) return a.id < b.id end)
  for _, l in ipairs({near or {}, sd and sd.doors or {}, reo}) do
    for _, d in ipairs(l) do
      if int(d.id) and not seen[d.id] then seen[d.id] = true; cand[#cand + 1] = d end
    end
  end
  rt.door_pts = cand
  local h = st.hold
  if h and not h.doors_at then h.doors_at, dirty = now, true end
  local late = doors_late(h, now)
  local mine, n, already, todo = {}, 0, 0, {}
  for _, id in ipairs(st.doors) do mine[id] = true end
  for _, d in ipairs(cand) do
    if not mine[d.id] then
      local b = df.building.find(d.id)
      local f = b and b.door_flags and b.door_flags.forbidden
      local r, ri = find_ref(d.id)
      if b and f then
        already = already + 1
        if r then table.remove(st.ref, ri); dirty = true end   -- forbidden by someone else meanwhile: not ours
      elseif b and not (r and not retry_due(K, r, now)) then todo[#todo + 1] = d end
    end
  end
  local out, nout = {}, 0
  if #todo > 0 and not late then out, nout = door_outside(K, todo) end
  local wait = {}
  for _, d in ipairs(todo) do
    local need = not late and needers(d.id) or 0           -- BUG-035: opened again for a recalled citizen
    if need > 0 and (out[d.id] or 0) == 0 then nout = nout + need end
    if late or ((out[d.id] or 0) == 0 and need == 0) or hostile_near(K, d.pos, now) then
      -- BUG-035: the citizens it was opened for are locked out by it now (the recall reports them, they hold no door)
      for uid in pairs(rt.need and rt.need[d.id] or {}) do
        local g = rt.dg and rt.dg[uid]
        if g and g.key == 'door:' .. d.id then g.key, g.path = 'locked:' .. d.id, 'locked:' .. d.id end
      end
      if rt.need then rt.need[d.id] = nil end
      local r = find_ref(d.id)
      local ok
      if r then
        local _, _, _, on = tile_sig(K, r.pos)
        ok = K.act.door_forbid(d.id, true, on == 0)            -- the retry closes it too, nobody in the doorway
      else ok = K.act.door_forbid(d.id, true) end
      if ok then
        n, mine[d.id] = n + 1, true
        if rt.reo then rt.reo[d.id] = nil end
        st.doors[#st.doors + 1] = d.id
        st.vfy[#st.vfy + 1] = {id = d.id, t = now, try = r and 2 or 1, pos = d.pos}
        if r then
          r.try = 2                                              -- the one retry is spent
          K.log('info', 'reflex: door %d (%d,%d,%d) tried again (forbidden + closed)', d.id, d.pos[1], d.pos[2],
                d.pos[3])
        end
        dirty = true
      end
    else wait[#wait + 1] = d.id end
  end
  rt.wait, rt.wait_out = wait, #wait > 0 and nout or 0
  local s = string.format('doors %d forbidden', #st.doors)
  if #wait > 0 then
    s = s .. string.format(', %d waiting for %d citizen%s outside', #wait, rt.wait_out, rt.wait_out == 1 and '' or 's')
  end
  if already > 0 then s = s .. ' (' .. already .. ' were already)' end
  local pl, refs = {}, refused_now()
  for i, r in ipairs(refs) do
    if i > M.REF_SHOWN then pl[#pl] = pl[#pl] .. ' +' .. (#refs - M.REF_SHOWN); break end
    pl[#pl + 1] = ref_text(r)
  end
  if sd and #sd.open > 0 then
    local l = {}
    for i, o in ipairs(sd.open) do
      if i > M.OPEN_SHOWN then break end
      l[#l + 1] = string.format('%s %d,%d,%d', o.kind, o.pos[1], o.pos[2], o.pos[3])
    end
    local more = #sd.open - #l
    pl[#pl + 1] = string.format('%s%s %s no door', table.concat(l, ', '), more > 0 and (' +' .. more) or '',
                                #sd.open == 1 and 'has' or 'have')
  end
  if #pl > 0 then s = s .. ', partial lockdown: ' .. table.concat(pl, ', ') end
  if not sd and sstate == 'pending' then s = s .. ', entrance check pending' end
  return s, n
end

-- BUG-015: LOCKDOWN_PARTIAL (A) for the doors refused so far (cadence: the first refusal of a lockdown at once, a new
-- door or a failed retry again after max(7 days, 10 min); a lockdown is one episode)
local function announce_refused(K, now, r)
  local refs = refused_now()
  if #refs == 0 then return end
  local ids, toks = {}, {}
  for _, x in ipairs(refs) do
    ids[#ids + 1] = x.id
    toks[#toks + 1] = x.id .. ':' .. (x.try == 1 and 'retry' or 'final')
  end
  local T = K.now()
  local due = CAD.due(st.prec, T, ids, toks)
  local what = string.format('door %d (%d,%d,%d) refused (flag reset; %d items, %d units on or next to its tile)',
                             r.id, r.pos[1], r.pos[2], r.pos[3], r.items or 0, r.units or 0)
  local next_ = r.try == 1 and string.format('one retry (forbidden + closed) once that changes (<= %d ticks)',
                                              M.DOOR_RETRY) or 'the retry failed too'
  if not due then
    K.log('warn', 'reflex: %s, %s', what, next_)
    return
  end
  st.prec, dirty = CAD.mark(T, ids, toks), true
  local parts = {what, next_, string.format('doors %d held', #st.doors)}
  if #refs > 1 then parts[#parts + 1] = string.format('%d refused in all', #refs) end
  K.emit('LOCKDOWN_PARTIAL', 'A', compose('partial lockdown: ', parts),
         {doors = #st.doors, refused = ids, pos = {r.pos[1], r.pos[2], r.pos[3]}, retry = r.try == 1 and 1 or 0,
          items = r.items or 0, units = r.units or 0})
end

-- BUG-015 (Run 10 test fort: door 16970's flag read false one frame after act.door_forbid, "doors 1 forbidden"
-- nevertheless): the doors forbidden on an earlier pass are read back. Held: they count. Fell back: the door leaves
-- st.doors (the count, the undo), joins st.ref with what stands on its tile, and LOCKDOWN_PARTIAL says so; held on the
-- retry: the refusal ends; fell back on the retry: it stays refused for this lockdown.
local function verify_doors(K, now)
  if #st.vfy == 0 then return end
  local keep, last = {}, nil
  for _, v in ipairs(st.vfy) do
    if now == v.t then keep[#keep + 1] = v
    else
      local b = df.building.find(v.id)
      local f = b and b.door_flags and b.door_flags.forbidden
      local r, ri = find_ref(v.id)
      if not b then
        drop_door(v.id)
        if r then table.remove(st.ref, ri) end
      elseif f then
        if r then
          table.remove(st.ref, ri)
          K.log('info', 'reflex: door %d (%d,%d,%d) held on the retry', v.id, v.pos[1], v.pos[2], v.pos[3])
        end
      else
        drop_door(v.id)
        local sig, ni, nu = tile_sig(K, v.pos)
        if r then r.t, r.try, r.sig, r.items, r.units = now, 2, sig, ni, nu
        else
          r = {id = v.id, t = now, try = 1, pos = v.pos, sig = sig, items = ni, units = nu}
          st.ref[#st.ref + 1] = r
        end
        K.log('warn', 'reflex: door %d (%d,%d,%d) refused: forbidden flag reset after %d ticks (try %d; %d items, ' ..
              '%d units on or next to the tile)', v.id, v.pos[1], v.pos[2], v.pos[3], now - v.t, r.try, ni, nu)
        last = r
      end
    end
  end
  st.vfy, dirty = keep, true
  if last then announce_refused(K, now, last) end
end

-- undo after quiet: exactly the doors this lockdown forbade (st.doors), the ones still forbidden; a refused door
-- (BUG-015) is not among them and is never counted
local function open_doors(K)
  local n = 0
  for _, id in ipairs(st.doors) do
    local b = df.building.find(id)
    if b and b.door_flags and b.door_flags.forbidden then
      if K.act.door_forbid(id, false) then n = n + 1 end
    end
  end
  local nref = #refused_now()
  st.doors, st.vfy, st.ref, st.prec, dirty = {}, {}, {}, nil, true
  rt.seal_tick, rt.door_pts, rt.wait, rt.wait_out, rt.ref_t = nil, nil, nil, nil, nil
  rt.need, rt.reo, rt.nohold, rt.rout, rt.dg, rt.rm = nil, nil, nil, nil, nil, nil   -- BUG-035: the recall's doors
  return n, nref
end

---------------------------------------------------------------- Run 11: approach and expired far
M.FAR_MAX = 40             -- hostiles kept as expired far (st.far), the newest
M.FAR_SHOWN = 3            -- named in LOCKDOWN_END
M.FAR_PRUNE = 1200         -- ticks between looks at expired-far units not listed: dead or gone ones are dropped
local FAR_MODES = {PEACE = true, ALERT = true}   -- the quiet clock runs past far invaders only there (never in a siege)

local function far_set()
  local f, hl = {}, {}
  for _, id in ipairs(st.far and st.far.ids or {}) do f[id] = true end
  for _, id in ipairs(st.far and st.far.hl or {}) do if f[id] then hl[id] = true end end   -- BUG-065: cleared harmless ones
  rt.fset, rt.hlset = f, hl
end

local function far_drop(gone)
  local keep, khl = {}, {}
  for _, id in ipairs(st.far.ids) do if not gone[id] then keep[#keep + 1] = id end end
  for _, id in ipairs(st.far.hl or {}) do if not gone[id] then khl[#khl + 1] = id end end
  st.far.ids, st.far.hl, dirty = keep, khl, true
  far_set()
end

-- the entrance points an approach is measured to: gate's (manifest O1 centres, else the unmanaged bridges in hand), the
-- lockdown's doors (else the open-sky door scan) and seal's entrance tiles; the last non-empty set is kept (the doors
-- leave rt.door_pts when a lockdown ends, gate hands the unmanaged bridges back)
local function entry_pts(K)
  local pts = {}
  local okg, gp = K.call('gate', 'points')
  for _, p in ipairs(okg and type(gp) == 'table' and gp or {}) do
    if type(p) == 'table' and int(p.x) and int(p.y) and int(p.z) then pts[#pts + 1] = {x = p.x, y = p.y, z = p.z} end
  end
  for _, d in ipairs(rt.door_pts or (rt.doors and rt.doors.list) or {}) do
    pts[#pts + 1] = {x = d.pos[1], y = d.pos[2], z = d.pos[3]}
  end
  local oke, ent = K.call('seal', 'entrances')
  for _, p in ipairs(oke and type(ent) == 'table' and ent or {}) do
    if type(p) == 'table' and int(p[1]) and int(p[2]) and int(p[3]) then pts[#pts + 1] = {x = p[1], y = p[2], z = p[3]} end
  end
  if #pts > 0 then rt.epts = pts end
  return rt.epts or pts
end

local function nearest(e, pts)
  local best = -1
  for _, p in ipairs(pts) do
    local d = geom.dist(e, p)
    if best < 0 or d < best then best = d end
  end
  return best
end

-- per listed hostile of census h, rt.ap[id] = {near, how ('inside' | 'citizen' | 'entrance' | 'off'), unknown, dc, de,
-- d, e}: near = inside Kern+ / past B1 (zone 2), or within lockdown_near of a citizen outside Kern+ (sense dc) or of an
-- entrance (de), every one with lockdown_near 0 (off); unknown = neither distance known; else far, d = the smaller known
-- distance. An expired-far hostile that is near leaves st.far (rt.appr names it for the sighting); one not listed is
-- dropped once its unit is dead or gone (every FAR_PRUNE ticks)
local function far_scan(K, h, now)
  rt.ftick = h.tick
  local L = cfg(K).lockdown_near
  if L == 0 and #st.far.ids > 0 then st.far.ids, dirty = {}, true; far_set() end
  local ap, list = {}, h.list or {}
  local pts = #list > 0 and entry_pts(K) or {}
  local fs, gone = rt.fset, nil
  for _, e in ipairs(list) do
    local dc, de = int(e.dc) or -1, nearest(e, pts)
    local r = {dc = dc, de = de, e = e, d = (dc >= 0 and de >= 0) and math.min(dc, de) or math.max(dc, de)}
    if (e.zn or 0) == 2 then r.near, r.how = true, 'inside'
    elseif L == 0 then r.near, r.how = true, 'off'
    elseif dc >= 0 and dc <= L then r.near, r.how = true, 'citizen'
    elseif de >= 0 and de <= L then r.near, r.how = true, 'entrance'
    elseif r.d < 0 then r.unknown = true end
    ap[e.id] = r
    -- BUG-065: a cleared harmless intruder stays cleared when it is near (only inside Kern+ it counts again)
    if fs[e.id] and r.near and not (rt.hlset[e.id] and r.how ~= 'inside') then
      gone = gone or {}
      gone[e.id] = true
      local what = r.how == 'inside' and 'inside Kern+' or string.format('%d tiles of %s', r.how == 'citizen' and dc or de,
                                                                          r.how == 'citizen' and 'a citizen' or 'an entrance')
      rt.appr = {id = e.id, k = e.an == 1 and 'animal' or e.k, what = what}
      K.log('info', 'reflex: %s %d at %d,%d,%d came within %s after its lockdown ended far: it counts again',
            rt.appr.k, e.id, e.x, e.y, e.z, what)
    end
  end
  if next(rt.hlset) then                  -- BUG-065: any other hostile in sight and the cleared ones count again
    local others = false
    for _, e in ipairs(list) do if not fs[e.id] then others = true; break end end
    if others then
      gone = gone or {}
      local n = 0
      for id in pairs(rt.hlset) do gone[id] = true; n = n + 1 end
      K.log('info', 'reflex: another hostile is in sight: %d cleared harmless intruder%s count again', n, n == 1 and '' or 's')
    end
  end
  if not gone and #st.far.ids > 0 and (now - (rt.fprune or -M.FAR_PRUNE) >= M.FAR_PRUNE or now < (rt.fprune or now)) then
    rt.fprune = now
    for _, id in ipairs(st.far.ids) do
      if not ap[id] then
        local ok, alive = pcall(function()
          local u = df.unit.find(id)
          return u ~= nil and dfhack.units.isActive(u) and not dfhack.units.isDead(u)
        end)
        if ok and not alive then gone = gone or {}; gone[id] = true end
      end
    end
  end
  if gone then far_drop(gone) end
  rt.ap = ap
end

-- public (K.call, threat.assess): the visible hostiles whose lockdown expired far, {[id] = true} (read-only). A fresh
-- census is scanned first, so one that came near counts again in the same pass
function M.far_ids(K)
  if not st then return {} end
  local h = K.census.h
  if #st.far.ids > 0 and type(h) == 'table' and h.tick ~= rt.ftick and K.now().tick - (h.tick or -1e9) <= M.FRESH then
    local ok, err = pcall(far_scan, K, h, K.now().tick)
    if not ok then
      rt.ftick = h.tick
      K.log('warn', 'reflex: far scan failed: %s', tostring(err))
    end
  end
  return rt.fset
end

-- the quiet clock may run past the visible invaders: PEACE/ALERT, lockdown_near on, the census lists every invader and
-- each one is far (not near, distance known)
local function far_now(K, h)
  if cfg(K).lockdown_near == 0 or not FAR_MODES[K.mode()] or rt.ftick ~= h.tick then return false end
  local listed = 0
  for _, e in ipairs(h.list or {}) do
    if e.k == 'inv' then
      listed = listed + 1
      local a = rt.ap and rt.ap[e.id]
      if not a or a.near or a.unknown then return false end
    end
  end
  return listed >= (h.inv or 0)
end

-- why the unit of an interrupt is far now (expired far, or listed beyond lockdown_near), or nil
local function unit_far(K, u)
  u = int(u)
  if not u or cfg(K).lockdown_near == 0 then return nil end
  if rt.fset[u] then return 'expired far' end
  local h = K.census.h
  local a = rt.ap and rt.ap[u]
  if a and type(h) == 'table' and rt.ftick == h.tick and K.now().tick - (h.tick or -1e9) <= M.FRESH
     and not a.near and not a.unknown then
    return string.format('%d tiles from the citizens and entrances', a.d)
  end
end

local function race_of(id)
  local ok, r = pcall(function() return dfhack.units.getRaceName(df.unit.find(id)) end)
  return ok and type(r) == 'string' and r ~= '' and r or '?'
end

-- at a lockdown's end: the listed hostiles beyond lockdown_near (invaders first, then by distance) are named ('inv 300
-- GOBLIN at 150,30,10 (99 tiles)'); the invaders among them become expired far (st.far: the quiet clock saw every
-- invader far for hold_quiet_days, it tracks no other kind). Returns the names and their number
local function far_mark(K, now)
  local h = K.census.h
  if cfg(K).lockdown_near == 0 or type(h) ~= 'table' or rt.ftick ~= h.tick or not rt.ap then return {} end
  local l = {}
  for _, e in ipairs(h.list or {}) do
    local a = rt.ap[e.id]
    if a and not a.near and not a.unknown then l[#l + 1] = a end
  end
  table.sort(l, function(p, q)
    local pi, qi = p.e.k == 'inv', q.e.k == 'inv'
    if pi ~= qi then return pi end
    if p.d ~= q.d then return p.d < q.d end
    return p.e.id < q.e.id
  end)
  local names, have = {}, {}
  for _, id in ipairs(st.far.ids) do have[id] = true end
  for _, a in ipairs(l) do
    local e = a.e
    if #names < M.FAR_SHOWN then
      names[#names + 1] = string.format('%s %d %s at %d,%d,%d (%d tiles)', e.an == 1 and 'animal' or e.k, e.id,
                                        race_of(e.id), e.x, e.y, e.z, a.d)
    end
    if e.k == 'inv' and not have[e.id] then
      have[e.id] = true
      st.far.ids[#st.far.ids + 1] = e.id
    end
  end
  while #st.far.ids > M.FAR_MAX do table.remove(st.far.ids, 1) end
  if #l > 0 then st.far.t, dirty = now, true end
  far_set()
  return names, #l
end

---------------------------------------------------------------- hold and the actions
local function holding(K, what)
  local h = st and st.hold
  if not h then return nil end
  if what and not h.acts[what] then return nil end
  if what == 'alert' and not h.alert_on then return nil end   -- deferred until the gates are up (ALERT_AFTER)
  return h.why
end

-- public (K.call): why a lockdown holds `what` ('clock'|'gates'|'alert'|'doors'; nil = any), or nil. The arbiter,
-- gate and siege ask it every pass (level-triggered); after a reload the persisted hold answers at once.
function M.holding(K, what) return holding(K, what) end

local function sorted(set)
  local r = {}
  for k in pairs(set) do r[#r + 1] = k end
  table.sort(r)
  return r
end

-- BUG-013: how long the lockdown's civ alert may wait for its lever pulls, from the last lever latency in ticks
local function alert_wait(lat)
  lat = int(lat)
  if not lat or lat < 0 then return M.ALERT_UNKNOWN end
  return math.max(M.ALERT_AFTER, math.min(M.ALERT_MAX, M.ALERT_LAT * lat))
end

local function plural(n, word) return n == 1 and word or word .. 's' end

-- BUG-013: what the gates hold, from gate.pulls (or gate.lockdown's info): 'gates: 2 of 4 up, 2 pulls pending',
-- 'gates: 2 of 4 up, 2 pulls blocked (levers outside the alert burrow)', '... pending (levers in Hebel+)'
local function gates_text(p)
  local want, up = int(p.want) or 0, int(p.up) or 0
  if want == 0 then return 'gates: no lever-linked bridge' end
  local left, out = int(p.left) or 0, int(p.out) or 0
  local foot, nl = int(p.foot) or 0, int(p.nolever) or 0
  local s = string.format('gates: %d of %d up', up, want)
  if left - out > 0 then
    s = s .. string.format(', %d %s pending%s', left - out, plural(left - out, 'pull'),
                           type(p.lb) == 'string' and (' (levers in ' .. p.lb .. ')') or '')
  end
  if out > 0 then
    s = s .. string.format(', %d %s blocked (levers outside the alert burrow)', out, plural(out, 'pull'))
  end
  if foot > 0 then s = s .. string.format(', %d waiting for a citizen on the bridge', foot) end
  if nl > 0 then s = s .. string.format(', %d without a linked lever', nl) end
  return s
end

-- gate.pulls, or false without the gate module
local function pulls(K)
  local ok, p = K.call('gate', 'pulls')
  return ok and type(p) == 'table' and p or false
end

-- Run 11: the citizens (soldiers excluded) outside Kern+ and the refuge in a fresh census (sense), 0 when none or not
-- known (no Kern+ burrow: -1, an old census)
local function outside_now(K, now)
  local cu = K.census.u
  if type(cu) ~= 'table' or now - (int(cu.tick) or -1e9) > M.FRESH then return 0 end
  return math.max(0, int(cu.outside) or 0)
end

-- BUG-013: why the lockdown's deferred civ alert sounds now, or nil; p = gate.pulls (fetched when nil). At once when
-- a hostile is near a citizen outside Kern+ or inside, when citizens are outside Kern+ (Run 11: call them home first;
-- the pulls go on under the alert with the lever burrow listed) or when the lockdown raises no gate; else once no lever
-- pull is pending (the gates are up or none is left to pull), or at its deadline hd.alert_at. Returns why, p.
local function alert_due(K, hd, now, p)
  local hc = K.census.h
  if type(hc) == 'table' and (((hc.near_cit or -1) >= 0 and hc.near_cit <= M.ALERT_NEAR) or (hc.inside or 0) > 0) then
    return 'hostile near', p
  end
  if hd.acts.gates and p == nil then p = pulls(K) end
  -- BUG-027: a bridge waits for units on its footprint: call the civilians in first (the gate raises once it is clear)
  if hd.acts.gates and p and (int(p.foot) or 0) > 0 then return 'units on a bridge', p end
  local out = outside_now(K, now)
  if out > 0 then return string.format('%d %s outside Kern+', out, plural(out, 'citizen')), p end
  if not hd.acts.gates then return 'no gates', p end
  if not p then return 'no gate module', p end
  if (int(p.left) or 0) == 0 then
    local want = int(p.want) or 0
    return (want > 0 and (int(p.up) or 0) >= want) and 'gates up' or 'no pull pending', p
  end
  if hd.alert_at and now >= hd.alert_at then
    local left = int(p.left) or 0
    return string.format('deadline %d ticks, %d %s left', hd.wait or 0, left, plural(left, 'pull')), p
  end
  return nil, p
end

-- the deferred alert's deadline, set once per lockdown from the lever latency gate measured last
local function alert_deadline(hd, now, p)
  if hd.alert_at then return end
  hd.wait = alert_wait(p and p.lat_t)
  hd.alert_at, dirty = now + hd.wait, true
end

---------------------------------------------------------------- Run 11: the recall (citizens outside called home)
-- the burrows the sounding civ alert confines to (siege's list, its own burrow first), {} while it is silent
local function alert_now(K)
  local ok, names = K.call('siege', 'alert_names')
  return ok and type(names) == 'table' and names or {}
end

local function outside_ids(K)
  local cu, ids = K.census.u, {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    if #ids < M.RECALL_IDS and int(id) then ids[#ids + 1] = int(id) end
  end
  return ids
end

-- the fort's Kern+ and refuge burrow names (manifest roles kern/refuge; sense, gate and siege read them alike)
local function core_names(K)
  local man = K.manifest()
  local kern, refuge
  local bs = type(man.burrows) == 'table' and man.burrows or {}
  local names = {}
  for name in pairs(bs) do if type(name) == 'string' then names[#names + 1] = name end end
  table.sort(names)
  for _, name in ipairs(names) do
    local role = type(bs[name]) == 'table' and bs[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  return kern or 'Kern+', refuge or 'Tiefe+'
end

-- BUG-035 (Run 11, the ambush after siege 9: the alert held the citizens in Tiefe+, the recall texts said 'outside
-- Kern+'): the burrows a recall measures arrival in: the sounding alert's own burrow (siege lists it first) and any of
-- Kern+, the refuge and Innen+ it lists too; the lever burrows (Hebel+, the dfllm-levers rooms) are no destination
M.INTERIOR = 'Innen+'
local function target(K, names)
  local t, seen = {}, {}
  if #names == 0 then return t end
  local kern, refuge = core_names(K)
  local core = {[kern] = true, [refuge] = true, [M.INTERIOR] = true}
  for i, n in ipairs(names) do
    if type(n) == 'string' and not seen[n] and (i == 1 or core[n]) then seen[n], t[#t + 1] = true, n end
  end
  return t
end

local function sig(l) return table.concat(type(l) == 'table' and l or {}, '/') end

-- the burrows a recall's texts name: its burrows, else (not called: the alert lists none) Kern+
local function rc_where(K, rc)
  if rc and type(rc.to) == 'table' and #rc.to > 0 then return sig(rc.to) end
  return (core_names(K))
end

-- sense counts the citizens on none of `names` from now on (census.u away/away_ids/away_to; nil stops it)
local function recount(K, names)
  K.call('sense', 'recount', names)
  rt.aw_sig = names and sig(names) or nil
end

-- BUG-035 (Run 11 siege 9: 'recall: 9 of 5 still outside' as the alert moved the citizens from Kern+ to Tiefe+): the
-- recall follows the citizens it called (rc.ids, sorted) instead of the live total. From census.u: sense's away list
-- when it measured rc.to, else the citizens outside Kern+ and the refuge. Returns nil without a usable count, else
-- {still = start ids still out, new = ids out now that were not out at the alert, tot = out now, extra = start ids out
-- beyond a cut list (an estimate; 0 while the list holds them all)}
local function measure(rc, cu)
  local list, tot
  if type(rc.to) == 'table' and #rc.to > 0 and sig(cu.away_to) == sig(rc.to) and int(cu.away) then
    list, tot = type(cu.away_ids) == 'table' and cu.away_ids or {}, int(cu.away)
  else
    list, tot = type(cu.outside_ids) == 'table' and cu.outside_ids or {}, int(cu.outside)
  end
  if not tot or tot < 0 then return nil end
  local inl, maxl = {}, -1
  for _, id in ipairs(list) do
    if int(id) then inl[id] = true; if id > maxl then maxl = id end end
  end
  local cut, start, still, maybe = tot > #list, {}, {}, 0
  for _, id in ipairs(rc.ids) do
    start[id] = true
    if inl[id] then still[#still + 1] = id
    elseif cut and id > maxl then maybe = maybe + 1 end
  end
  local new = {}
  for _, id in ipairs(list) do if int(id) and not start[id] then new[#new + 1] = id end end
  local extra = math.min(maybe + math.max(0, rc.n - #rc.ids), math.max(0, tot - #list))
  return {still = still, new = new, tot = tot, extra = extra}
end

---------------------------------------------------------------- BUG-035: why a citizen is not in (read-only)
-- Run 11 (siege 9 and the ambush after it: the same two citizens, unhurt, idle, on the citizens' only walk group, never
-- came in; the doors waited 2,400 ticks for one of them). Per citizen still out of the recall's burrows, by census id:
-- gone (dead, not found), caged, chained, carried (flags1.rider: a baby carried, a snatched child [? live]), mood (a
-- strange mood), down (unconscious or lying on the ground), patient (job Rest: a hospital bed), sleep (job Sleep),
-- puller:<room> (gate holds him by its levers), burrow:<name> (his own burrow assignment, burrows screen > units, to a
-- burrow the alert does not list), walk (his path ends in the recall's burrows), job:<type> (a job elsewhere), away (a
-- path elsewhere), idle (no job, no path); seal's path check (recall_path, for one who could come, RECALL_PATH ticks
-- after the alert) adds door:<id> (his only way crosses doors this lockdown forbade: they open again for him),
-- locked:<id> (a door the player forbade, a hostile at it, or the doors stopped waiting), group (no tile of the burrows
-- on his walk group) and path (no way within its bound). /res marks a resident who is no citizen.
M.NOHOLD = {gone = true, caged = true, chained = true, carried = true, mood = true, down = true, patient = true,
            sleep = true, puller = true, burrow = true, locked = true, group = true, path = true}
M.EXCUSED = {gone = true, puller = true}   -- never counted as still out (the dead; gate's pullers stay on purpose)
M.RECALL_DIAG = 300        -- ticks a diagnosis is kept for a citizen still out
M.RECALL_PATH = 600        -- ticks after the alert before seal's path check for one who could come but is still out
M.RECALL_SHOWN = 20        -- ids and reasons in RECALL d
M.TOK_SHOWN = 4            -- reasons named in a text

local function key_kind(key) return (tostring(key or ''):match('^([%a_]+)')) end

local function try(f)
  local ok, v = pcall(f)
  if ok then return v end
end

-- what a diagnosis needs once per poll: gate's pullers, burrow id -> name, the alert's burrows (resolved)
local function diag_ctx(K, rc, names)
  local okp, pul = K.call('gate', 'puller_of')
  local c = {pullers = okp and type(pul) == 'table' and pul or {}, bnames = {}, listed = {}, tb = {}}
  pcall(function()
    for _, b in ipairs(df.global.plotinfo.burrows.list) do c.bnames[b.id] = b.name end
  end)
  for _, n in ipairs(names or {}) do c.listed[n] = true end
  for _, n in ipairs(rc.to or {}) do
    c.listed[n] = true
    local b = dfhack.burrows.findByName(n)
    if b then c.tb[#c.tb + 1] = b end
  end
  return c
end

local function diag(K, c, id)
  local U = dfhack.units
  local u = df.unit.find(id)
  if not u or try(function() return U.isDead(u) end) == true then return {key = 'gone'} end
  local x, y, z = U.getPosition(u)
  if not x then return {key = 'gone'} end
  local r = {x = x, y = y, z = z}
  if try(function() return U.isResident(u) and not U.isCitizen(u) end) == true then r.res = true end
  local function f1(k) return try(function() return u.flags1[k] end) == true end
  local job = try(function() return u.job.current_job end)
  local jt = job and try(function() return job.job_type end)
  local function is(name)
    local v = try(function() return df.job_type[name] end)
    return v ~= nil and jt == v
  end
  local dest = try(function()
    local d = u.path.dest
    if d.x >= 0 then return {x = d.x, y = d.y, z = d.z} end
  end)
  if f1('caged') then r.key = 'caged'
  elseif f1('chained') then r.key = 'chained'
  elseif f1('rider') then r.key = 'carried'
  elseif (try(function() return u.mood end) or -1) >= 0 then r.key = 'mood'
  elseif (try(function() return u.counters.unconscious end) or 0) > 0 or f1('on_ground') then r.key = 'down'
  elseif is('Rest') then r.key = 'patient'
  elseif is('Sleep') then r.key = 'sleep'
  elseif c.pullers[id] then r.key = 'puller:' .. tostring(c.pullers[id])
  else
    local own
    pcall(function()
      for _, bid in ipairs(u.burrows) do
        local n = c.bnames[bid]
        if n and not c.listed[n] then own = own or n end
      end
    end)
    local walk = false
    if dest then
      for _, b in ipairs(c.tb) do
        if dfhack.burrows.isAssignedTile(b, dest) then walk = true; break end
      end
    end
    if own then r.key = 'burrow:' .. own
    elseif walk then r.key = 'walk'
    elseif jt then r.key = 'job:' .. tostring(try(function() return df.job_type[jt] end) or jt)
    elseif dest then r.key = 'away'
    else r.key = 'idle' end
  end
  return r
end

-- '28346:locked:16970@135,77,137/d12/res'
local function token(id, g)
  if not g or not g.x then return string.format('%d:%s', id, g and g.key or '?') end
  return string.format('%d:%s@%d,%d,%d%s%s', id, g.key, g.x, g.y, g.z, (g.d or -1) >= 0 and ('/d' .. g.d) or '',
                       g.res and '/res' or '')
end

local function tokens(ids, n)
  local l = {}
  for _, id in ipairs(ids) do
    if #l >= (n or M.RECALL_SHOWN) then break end
    l[#l + 1] = token(id, rt.dg and rt.dg[id]):sub(1, 60)
  end
  return l
end

-- the door(s) of a path check's answer: all this lockdown's own (st.doors, or opened again for a recalled citizen
-- already) and no hostile within DOOR_NEAR: opened again, they wait for him (forbid_doors); else 'locked:<id>'
local function reopen(K, rc, id, doors, now)
  local mine = {}
  for _, d in ipairs(st.doors) do mine[d] = true end
  rt.need = rt.need or {}
  for _, did in ipairs(doors) do
    if not mine[did] and not rt.need[did] then return 'locked:' .. did end
  end
  if rc.late then return 'locked:' .. doors[1] end
  for _, did in ipairs(doors) do
    if mine[did] then
      local b = df.building.find(did)
      local p = b and door_pos(b)
      if not p or hostile_near(K, p, now) or not K.act.door_forbid(did, false) then return 'locked:' .. did end
      drop_door(did)
      for i = #st.vfy, 1, -1 do if st.vfy[i].id == did then table.remove(st.vfy, i) end end
      dirty = true
      rt.reo = rt.reo or {}
      rt.reo[did] = {id = did, pos = p}                        -- forbid_doors looks at it again (it waits for him)
      rt.wait = rt.wait or {}
      rt.wait[#rt.wait + 1] = did
      local g = rt.dg[id] or {}
      K.log('warn', 'reflex: recall: door %d (%d,%d,%d) opened again: citizen %d at %s has no way into %s without it ' ..
            '(seal path check); it waits for him', did, p[1], p[2], p[3], id,
            g.x and string.format('%d,%d,%d', g.x, g.y, g.z) or '?', rc_where(K, rc))
    end
    rt.need[did] = rt.need[did] or {}
    rt.need[did][id] = true
  end
  return 'door:' .. doors[1]
end

-- a fresh (or kept) diagnosis for each id; with `paths` seal's path check for those who could come, RECALL_PATH ticks
-- after the alert, again 2 x RECALL_PATH after its last answer (and at once after the alert moved), applied as soon as
-- seal has it: door (opened again for him) / locked, group, path; ok, far and unknown leave the diagnosis
local PATH_KEY = {group = 'group', none = 'path'}
local function diagnose(K, rc, ids, now, names, force, paths)
  rt.dg = rt.dg or {}
  local c
  for _, id in ipairs(ids) do
    local g = rt.dg[id]
    if force or not g or now - g.t >= M.RECALL_DIAG or now < g.t then
      c = c or diag_ctx(K, rc, names)
      local ng = diag(K, c, id)
      ng.t = now
      if g then ng.path, ng.pt, ng.d = g.path, g.pt, g.d end      -- the path check's answer stays
      if ng.path and not M.NOHOLD[key_kind(ng.key)] then ng.key = ng.path end
      rt.dg[id] = ng
    end
  end
  if not paths or #(rc.to or {}) == 0 or now - rc.t < M.RECALL_PATH then return end
  local ask = {}
  for _, id in ipairs(ids) do
    local g = rt.dg[id]
    if g and g.path ~= nil and now - (g.pt or now) >= 2 * M.RECALL_PATH then g.path = nil end
    if g and g.path == nil and (not M.NOHOLD[key_kind(g.key)] or key_kind(g.key) == 'locked') then ask[#ask + 1] = id end
  end
  if #ask == 0 then return end
  local ok, res = K.call('seal', 'recall_path', ask, rc.to, math.max(rt.pq_since or rc.t, now - M.RECALL_PATH))
  if not ok or type(res) ~= 'table' then return end
  for _, id in ipairs(ask) do
    local r, g = res[id], rt.dg[id]
    if type(r) == 'table' and g then
      local key = PATH_KEY[r.r]
      if r.r == 'door' and type(r.doors) == 'table' and #r.doors > 0 then key = reopen(K, rc, id, r.doors, now) end
      g.path, g.pt, g.d = key or false, now, int(r.d) or -1
      if key then g.key = key
      elseif key_kind(g.key) == 'locked' then g.key = 'idle' end    -- the door is open again (or another way)
    end
  end
end

-- the lockdown's alert has sounded: citizens out of the burrows it confines to start its recall (one per lockdown).
-- called = the alert really confines to a burrow (else they are not called: seal found no usable burrow, BUG-018);
-- BUG-035: measured against those burrows (sense counts again at once), each one diagnosed in kern.log
local function recall_start(K, h, now)
  if not h or h.rc then return end
  local names = alert_now(K)
  local to = target(K, names)
  local n, ids
  if #to > 0 then
    recount(K, to)
    local cu = K.census.u
    if type(cu) == 'table' and sig(cu.away_to) == sig(to) and int(cu.away) then
      n, ids = int(cu.away), {}
      for _, id in ipairs(type(cu.away_ids) == 'table' and cu.away_ids or {}) do
        if #ids < M.RECALL_IDS and int(id) then ids[#ids + 1] = int(id) end
      end
    end
  end
  if not n then n, ids = outside_now(K, now), outside_ids(K) end
  if n == 0 then
    if #to > 0 then recount(K, nil) end
    return
  end
  h.rc = {t = now, n = n, ids = ids, left = n, eta = (rt.eta or -1) >= 0 and rt.eta or -1, called = #names > 0,
          burrow = #to > 0 and sig(to) or nil, to = to, nnew = 0}
  rt.dg, rt.need, rt.rout, rt.nohold, rt.slog, rt.nlog, rt.pq_since, rt.rm = {}, {}, {}, {}, {}, {}, now, nil
  dirty = true
  local where = rc_where(K, h.rc)
  K.log(#names > 0 and 'info' or 'warn', 'reflex: recall: %d %s outside %s at the alert (%s)%s; %s', n,
        plural(n, 'citizen'), where, h.why,
        h.rc.eta >= 0 and string.format(', the nearest invader ~%d ticks from an entrance', h.rc.eta) or '',
        #names > 0 and string.format('called into %s, the doors wait for them up to %d ticks', where, M.RECALL_MAX)
                   or 'not called in: the civ alert does not sound (no usable burrow)')
  diagnose(K, h.rc, ids, now, names, true, false)
  K.log('info', 'reflex: recall: out at the alert: %s%s', table.concat(tokens(ids), ' '),
        n > #ids and string.format(' +%d not listed', n - #ids) or '')
end

-- the recall in the ARRIVAL/LOCKDOWN text: called (right after the alert, it matters most) 'recall: 16 outside Kern+',
-- 'recall: 7 of 16 still outside Tiefe+ after 600 t, +4 more out since, 2 cannot come', 'recall: 16 in within 640 t'; else
-- (after the gates, as before) '16 citizens outside Kern+' and, when the alert did not really sound, '(not called in:
-- no alert burrow)'. Returns the text and whether it is a called recall
local function recall_text(K, h, now, out)
  local rc = h and h.rc
  if not rc then
    return (out or 0) > 0 and string.format('%d %s outside %s', out, plural(out, 'citizen'), (core_names(K))) or nil,
           false
  end
  local where = rc_where(K, rc)
  if rc.done then
    local pull = rc.pull or 0
    if pull > 0 then
      return string.format('recall: %d of %d in within %d t, %d lever %s stay', rc.n - pull, rc.n, rc.done - rc.t, pull,
                           plural(pull, 'puller')), true
    end
    return string.format('recall: %d in within %d t', rc.n, rc.done - rc.t), true
  end
  local left = rc.left or rc.n
  if not rc.called then
    return string.format('%d %s outside %s (not called in: no alert burrow)', left, plural(left, 'citizen'), where), false
  end
  if now - rc.t < M.RECALL_POLL and left >= rc.n then return string.format('recall: %d outside %s', rc.n, where), true end
  local s = string.format('recall: %d of %d still outside %s after %d t', left, rc.n, where, now - rc.t)
  if (rc.nnew or 0) > 0 then s = s .. string.format(', +%d more out since', rc.nnew) end
  if (rc.stuck or 0) > 0 then s = s .. string.format(', %d cannot come', rc.stuck) end
  return s, true
end

-- RECALL (B): done | late | end, and BUG-035's stuck (once per lockdown: start ids that cannot come)
local function recall_event(K, h, now, why, m)
  local rc = h.rc
  local ticks = now - rc.t
  local where = rc_where(K, rc)
  local left = rc.left or 0
  local still, rest = {}, {}
  for _, id in ipairs(m and m.still or {}) do
    local g = rt.dg and rt.dg[id]
    local k = g and key_kind(g.key)
    if M.EXCUSED[k] then rest[#rest + 1] = id
    elseif M.NOHOLD[k] then still[#still + 1] = id               -- those who cannot come first
    else rest[#rest + 1] = id end
    -- the doors stopped waiting: a door opened again for him is forbidden again
    if g and rc.late and key_kind(g.key) == 'door' then
      g.key = (g.key:gsub('^door', 'locked'))
      g.path = g.key
    end
  end
  local ncant = #still
  for _, id in ipairs(rest) do
    local g = rt.dg and rt.dg[id]
    if not (g and M.EXCUSED[key_kind(g.key)]) then still[#still + 1] = id end
  end
  local new = m and m.new or {}
  local toks = tokens(still, why == 'stuck' and math.min(ncant, M.TOK_SHOWN) or M.TOK_SHOWN)
  local msg
  if why == 'done' then
    local pull = rc.pull or 0
    if pull > 0 then
      msg = string.format('recall (%s): %d of %d citizens outside %s at the alert came in within %d ticks, the other %d '
                          .. 'lever %s at the levers', h.why, rc.n - pull, rc.n, where, ticks, pull,
                          plural(pull, 'puller'))
    else
      msg = string.format('recall (%s): all %d %s outside %s at the alert came in within %d ticks', h.why, rc.n,
                          plural(rc.n, 'citizen'), where, ticks)
    end
    if rc.late then msg = msg .. string.format(' (%d ticks after the doors closed)', now - rc.late) end
  elseif why == 'late' then
    msg = string.format('recall (%s): %d of %d citizens still outside %s after %d ticks: the doors stop waiting for '
                        .. 'them', h.why, left, rc.n, where, ticks)
  elseif why == 'stuck' then
    msg = string.format('recall (%s): %d of %d citizens outside %s cannot come, the doors do not wait for them',
                        h.why, rc.stuck or 0, rc.n, where)
  else
    msg = string.format('recall (%s): the lockdown ended with %d of %d citizens still outside %s after %d ticks',
                        h.why, left, rc.n, where, ticks)
  end
  if why ~= 'stuck' and (rc.nnew or 0) > 0 then msg = msg .. string.format('; +%d more out of %s since', rc.nnew, where) end
  if #toks > 0 then msg = msg .. ' (' .. table.concat(toks, ' ') .. ')' end
  local d = {n = rc.n, left = left, ticks = ticks, why = why, called = rc.called and 1 or 0, eta = rc.eta}
  if #still > 0 then
    d.units = {}
    for i = 1, math.min(#still, M.RECALL_SHOWN) do d.units[i] = still[i] end
  end
  local all = {}
  for _, id in ipairs(m and m.still or {}) do all[#all + 1] = id end
  for _, id in ipairs(new) do all[#all + 1] = id end
  if #all > 0 then d.reasons = tokens(all) end
  if (rc.nnew or 0) > 0 then
    d.nnew, d.newu = rc.nnew, {}
    for i = 1, math.min(#new, M.RECALL_SHOWN) do d.newu[i] = new[i] end
  end
  if (rc.stuck or 0) > 0 then d.stuck = rc.stuck end
  if (rc.pull or 0) > 0 then d.pull = rc.pull end
  if rc.burrow then d.burrow = rc.burrow:sub(1, 60) end
  K.emit('RECALL', 'B', msg:sub(1, 200), d)
  K.log(why == 'done' and 'info' or 'warn', 'reflex: %s', msg)
  if #all > #toks then K.log('info', 'reflex: recall %s: %s', why, table.concat(tokens(all), ' ')) end
end

-- every RECALL_POLL ticks while a recall is open: the alert's burrows (one that sounds only now calls them; BUG-035: a
-- switch re-targets the recall), the start ids still out and those who left since, their diagnoses and path checks,
-- then all in (RECALL done), the first that cannot come (RECALL stuck, once), RECALL_MAX passed with some still out
-- (late: the doors close on them). Returns the measure (nil without a usable census)
local function recall_step(K, now, force)
  local h = st.hold
  local rc = h and h.rc
  if not rc or rc.done then return end
  if not force and now >= (rt.rc_t or -1e9) and now - (rt.rc_t or -1e9) < M.RECALL_POLL then return end
  rt.rc_t = now
  local names = alert_now(K)
  local to = target(K, names)
  if not rc.called and #names > 0 then
    rc.called, dirty = true, true
    K.log('info', 'reflex: recall: the civ alert sounds now (%s): %d citizens outside %s called in', names[1],
          rc.left or rc.n, sig(to))
  end
  if #to > 0 and sig(to) ~= sig(rc.to) then
    local from = rc_where(K, rc)
    rc.to, rc.burrow, dirty = to, sig(to), true
    recount(K, to)
    rt.dg, rt.pq_since = {}, now                             -- every diagnosis and path check against the new burrows
    local cu = K.census.u
    K.log('warn', 'reflex: recall: the civ alert moved from %s to %s %d ticks after it sounded: %d citizens not in %s ' ..
          'now; the recall follows its %d', from, rc.burrow, now - rc.t, type(cu) == 'table' and int(cu.away) or -1,
          rc.burrow, rc.n)
  elseif #to > 0 and rt.aw_sig ~= sig(to) then
    recount(K, to)                                           -- after a reload: sense counts against them again
  end
  local cu = K.census.u
  if type(cu) ~= 'table' or now - (int(cu.tick) or -1e9) > M.FRESH then return end
  local m = measure(rc, cu)
  if not m then return end
  rt.rm, rt.dg = m, rt.dg or {}
  diagnose(K, rc, m.still, now, names, false, true)
  -- those who left since the alert: diagnosed and named once each in kern.log
  local nd = {}
  for i = 1, math.min(#m.new, M.RECALL_SHOWN) do nd[i] = m.new[i] end
  diagnose(K, rc, nd, now, names, false, false)
  rt.nlog = rt.nlog or {}
  local fresh = {}
  for _, id in ipairs(nd) do if not rt.nlog[id] then rt.nlog[id] = true; fresh[#fresh + 1] = id end end
  if #fresh > 0 then
    K.log('warn', 'reflex: recall: %d more %s out of %s since the alert (%d ticks; not out at its start): %s', #fresh,
          plural(#fresh, 'citizen'), rc_where(K, rc), now - rc.t, table.concat(tokens(fresh), ' '))
  end
  rt.rout, rt.nohold = {}, {}
  local pull, stuck, sl, gone = 0, 0, {}, 0
  for _, id in ipairs(m.still) do
    rt.rout[id] = true
    local k = key_kind(rt.dg[id] and rt.dg[id].key)
    if M.NOHOLD[k] then rt.nohold[id] = true end
    if k == 'puller' then pull = pull + 1
    elseif k == 'gone' then gone = gone + 1
    elseif M.NOHOLD[k] then stuck, sl[#sl + 1] = stuck + 1, id end
  end
  for _, id in ipairs(nd) do
    if M.NOHOLD[key_kind(rt.dg[id] and rt.dg[id].key)] then rt.nohold[id] = true end
  end
  local left = #m.still - pull - gone + m.extra
  local nnew = math.max(0, m.tot - #m.still - m.extra)
  if left ~= rc.left or nnew ~= rc.nnew or stuck ~= (rc.stuck or 0) or pull ~= (rc.pull or 0) then
    rc.left, rc.nnew, rc.stuck, rc.pull, dirty = left, nnew, stuck, pull, true
  end
  rt.slog = rt.slog or {}
  if stuck > 0 then
    local news = {}
    for _, id in ipairs(sl) do if not rt.slog[id] then rt.slog[id] = true; news[#news + 1] = id end end
    if not rc.rep then
      rc.rep, dirty = now, true
      recall_event(K, h, now, 'stuck', m)
    elseif #news > 0 then
      K.log('warn', 'reflex: recall: %d more %s outside %s cannot come: %s', #news, plural(#news, 'citizen'),
            rc_where(K, rc), table.concat(tokens(news), ' '))
    end
  end
  if left == 0 then
    rc.done, dirty = now, true
    recall_event(K, h, now, 'done', m)
    recount(K, nil)                                          -- sense stops counting against its burrows
  elseif not rc.late and now - rc.t >= M.RECALL_MAX then
    rc.late, dirty = now, true
    recall_event(K, h, now, 'late', m)
  end
  return m
end

-- issue `acts` (idempotent); returns the parts of the text, in the order they matter (clock, alert, the recall or the
-- citizens outside, doors, gates, bridge names), and the d fields for the event
local function issue(K, acts, now)
  local part, d = {}, {}
  local want = {}
  for _, a in ipairs(acts) do want[a] = true end
  if want.clock then
    local ok, cap = K.call('arbiter', 'hold')
    d.clock = ok and int(cap) or 0
    part.clock = ok and string.format('clock %d t/s', d.clock) or 'clock: no arbiter'
  end
  local pinfo
  if want.gates then
    local ok, info = K.call('gate', 'lockdown')
    if ok and type(info) == 'table' then
      pinfo = info
      if #(info.names or {}) > 0 then part.names = table.concat(info.names, ',') end
    else
      d.raised, pinfo = 0, false
      part.gates = 'gates: no gate module'
    end
  end
  if want.doors then
    part.doors = forbid_doors(K, now, true)
    d.doors = #st.doors
  end
  if want.alert then
    local h = st.hold
    local due_why
    if h and not h.alert_on then
      local why, p = alert_due(K, h, now, pinfo)
      if why then h.alert_on, h.alert_t, dirty, due_why = true, now, true, why
      else alert_deadline(h, now, p) end
    end
    if not h or h.alert_on then
      -- BUG-011: siege's answer is what holds now (the burrow it sounded, or none and why), never the request
      local ok, r, short = K.call('siege', 'hold_alert')
      d.alert = ok and tostring(r):sub(1, 200) or 'none (no siege module)'
      if ok and type(short) == 'string' then part.alert = short end
      if due_why then K.log('info', 'reflex: civ alert: %s (%s)', d.alert, due_why) end
      recall_start(K, h, now)                                    -- Run 11: citizens outside are called in now
    else
      d.alert = string.format('after the gates (<= %d ticks)', math.max(0, (h.alert_at or now) - now))
    end
    local a = part.alert or d.alert
    part.alert = 'alert: ' .. (#a > M.ALERT_TEXT and (a:sub(1, M.ALERT_TEXT - 3) .. '...') or a)
  end
  if pinfo then
    -- BUG-013: the gates as they stand after the alert step (a sounding alert may have just listed the lever burrow)
    local p = pulls(K) or pinfo
    d.raised, d.up, d.left, d.blocked = int(p.want) or 0, int(p.up) or 0, int(p.left) or 0, int(p.out) or 0
    part.gates = gates_text(p)
  end
  local cu = K.census.u
  local out = type(cu) == 'table' and int(cu.outside) or nil
  if out and out > 0 then d.out = out end
  local h = st.hold
  local rtxt, called = recall_text(K, h, now, out and math.max(0, out) or nil)
  if called then part.recall = rtxt else part.out = rtxt end
  if h and h.rc then
    d.recall, d.rc_left = h.rc.n, h.rc.done and 0 or (h.rc.left or h.rc.n)
    if (h.rc.nnew or 0) > 0 then d.rc_new = h.rc.nnew end            -- BUG-035: left the alert's burrows since
  end
  local parts = {}
  for _, k in ipairs({'clock', 'alert', 'recall', 'doors', 'gates', 'out', 'names'}) do
    if part[k] then parts[#parts + 1] = part[k] end
  end
  return parts, d
end

-- start or extend the lockdown with `acts`; returns the parts of the text of what is in place, and d
local function engage(K, kind, why, acts, now)
  local h = st.hold
  if not h then
    h = {why = tostring(why):sub(1, 24), kinds = {}, acts = {}, since = now, last = now}
    st.hold = h
    rt.pull_sig, rt.pull_t = nil, nil
  end
  h.last, h.qs = now, nil
  -- an arrival names the lockdown even when an unacked interrupt's default started it (status: reason)
  if tostring(why):find('^arrival:') and not h.why:find('^arrival:') then h.why = tostring(why):sub(1, 24) end
  h.kinds[kind] = true
  for _, a in ipairs(acts) do h.acts[a] = true end
  dirty = true
  local parts, d = issue(K, sorted(h.acts), now)
  save(K)
  return parts, d
end

-- Run 11: cause 'far' when hostiles beyond lockdown_near are still in sight (named; they become expired far), else
-- 'quiet' (threat 0)
-- BUG-065: the hostiles a limit/need release clears: the harmless ones near (`pic.near`), named like far_mark's ones, and
-- put on the cleared list (st.far.ids + st.far.hl). Returns the names and their number
local function hl_clear(K, now, pic)
  local names, have = {}, {}
  for _, id in ipairs(st.far.ids) do have[id] = true end
  local mark = {}
  for _, id in ipairs(st.far.hl or {}) do mark[id] = true end
  for _, a in ipairs(pic and pic.near or {}) do
    local e = a.e
    names[#names + 1] = string.format('%s %d %s at %d,%d,%d (%s)', e.an == 1 and 'animal' or e.k, e.id,
                                      race_of(e.id), e.x, e.y, e.z, a.how == 'inside' and 'inside Kern+' or
                                      (a.d >= 0 and (a.d .. ' tiles') or 'distance unknown'))
    if not have[e.id] then have[e.id] = true; st.far.ids[#st.far.ids + 1] = e.id end
    if not mark[e.id] then mark[e.id] = true; st.far.hl[#st.far.hl + 1] = e.id end
  end
  while #st.far.ids > M.FAR_MAX do table.remove(st.far.ids, 1) end
  local keep = {}
  have = {}
  for _, id in ipairs(st.far.ids) do have[id] = true end
  for _, id in ipairs(st.far.hl) do if have[id] then keep[#keep + 1] = id end end
  st.far.hl, st.far.t, dirty = keep, now, true
  far_set()
  return names, #names
end

-- how: nil (threat 0 for hold_quiet_days, or 'far'), 'limit' (BUG-065: confine.max_days with nothing dangerous near) or
-- 'need' (a mood dwarf or patient in need behind the alert, nothing dangerous near); pic = confine_picture's answer,
-- who = the units in need ({id, why, th, hu})
local function release(K, now, how, pic, who)
  local h = st.hold
  if not h then return end
  local c = cfg(K)
  local names, nfar = far_mark(K, now)
  nfar = nfar or 0
  if how then
    local hn, nh = hl_clear(K, now, pic)
    for i = #hn, 1, -1 do table.insert(names, 1, hn[i]) end
    nfar = nfar + nh
  end
  if h.rc and not h.rc.done then                       -- Run 11: the recall ends with the lockdown
    local m = recall_step(K, now, true) or rt.rm
    if not h.rc.done then recall_event(K, h, now, 'end', m) end
  end
  if h.rc then recount(K, nil) end                     -- BUG-035: sense stops counting against its burrows
  st.hold, dirty = nil, true
  rt.pull_sig, rt.pull_t = nil, nil
  local n, nref = open_doors(K)
  K.call('arbiter', 'hold')
  -- the alert off before the gate pass: the lowering pulls are queued while nobody is confined (BUG-013)
  K.call('siege', 'hold_alert')
  K.call('gate', 'lockdown')
  local tail = string.format('%d doors opened%s', n, nref > 0 and string.format(', %d refused (flag reset)', nref) or '')
  local msg
  if how == 'limit' or how == 'need' then
    local head = how == 'limit' and string.format('confinement limit of %d days reached with no dangerous hostile near',
                                                  c.confine.max_days)
                 or string.format('%s %d is in need behind the alert and no dangerous hostile is near',
                                  who and who[1] and who[1].why or 'citizen', who and who[1] and who[1].id or 0)
    local parts = {head}
    if names[1] then parts[#parts + 1] = (how == 'limit' and 'harmless: ' or 'cleared: ') .. names[1] end
    for i = 2, math.min(#names, M.FAR_SHOWN) do parts[#parts + 1] = names[i] end
    if #names > M.FAR_SHOWN then parts[#parts + 1] = string.format('+%d', #names - M.FAR_SHOWN) end
    parts[#parts + 1] = tail
    msg = compose(string.format('lockdown over (%s): ', h.why), parts)
  elseif nfar > 0 then
    -- the quiet clock watched the invaders only: with one in sight it ran because each one stayed far
    local head = (names[1] or ''):find('^inv ') and string.format('no invader within %d tiles of a citizen or an ' ..
                 'entrance for %d days', c.lockdown_near, c.hold_quiet_days) or
                 string.format('threat 0 for %d days', c.hold_quiet_days)
    local parts = {string.format('%s, %d far: %s', head, nfar, names[1] or '?')}
    for i = 2, #names do parts[#parts + 1] = names[i] end
    if nfar > #names then parts[#parts + 1] = string.format('+%d', nfar - #names) end
    parts[#parts + 1] = tail
    msg = compose(string.format('lockdown over (%s): ', h.why), parts)
  else
    msg = string.format('lockdown over (%s): threat 0 for %d days; %s', h.why, c.hold_quiet_days, tail)
  end
  local d = {why = h.why, ticks = now - h.since, doors = n, cause = how or (nfar > 0 and 'far' or 'quiet')}
  if nref > 0 then d.refused = nref end
  if nfar > 0 then
    d.far, d.nfar = {}, nfar
    for i = 1, math.min(#names, M.FAR_SHOWN) do d.far[i] = names[i] end
  end
  st.cf = {o = CAD.quiet(st.cf and st.cf.o), n = CAD.quiet(st.cf and st.cf.n)}    -- BUG-065: a new episode waits
  K.emit('LOCKDOWN_END', 'B', msg, d)
  K.log('info', 'reflex: %s', msg)
end

---------------------------------------------------------------- interrupts and alarm.txt
-- number of unacked interrupts and the age of the oldest one in real seconds
local function unacked(K)
  local ack, n, oldest = st.ack.n or 0, 0, nil
  local ms = K.now().ms
  for _, r in ipairs(st.irq) do
    if r.n > ack then
      n = n + 1
      local age = math.max(0, ms - r.ms) // 1000
      if not oldest or age > oldest then oldest = age end
    end
  end
  return n, oldest
end

local function defcon(K)
  local mode, h = K.mode(), K.census.h
  local inside = type(h) == 'table' and (h.inside or 0) > 0
  local open = {}
  for _, r in ipairs(st.irq) do if r.n > (st.ack.n or 0) then open[r.done == 2 and 'far' or r.type] = true end end
  if mode == 'BREACH' or inside or open.INTRUDER then return 1 end
  local army = false
  for k in pairs(st.hold and st.hold.kinds or {}) do if ARMY[k] then army = true end end
  if mode == 'SIEGE' or army or open.ARRIVAL then return 2 end
  if mode == 'ALERT' or st.hold or next(open) then return 3 end
  local ok, armed = K.call('threat', 'armed')
  if mode == 'RECOVERY' or mode == 'DRILL' or (ok and armed == 1) then return 4 end
  return 5
end

local function alarm_text(K, dc)
  local n, oldest = unacked(K)
  local lock = st.hold and (st.hold.why .. ' (' .. table.concat(sorted(st.hold.acts), ',') .. ')') or 'off'
  local head = string.format('DEFCON %d | mode %s | unacked %d%s | last %d | ack %d | lockdown %s', dc, K.mode(), n,
                             oldest and string.format(' (oldest %d s)', oldest) or '',
                             st.irq[#st.irq] and st.irq[#st.irq].n or 0, st.ack.n or 0, lock)
  if rt.eta and rt.eta >= 0 then head = head .. string.format(' | eta ~%d t', rt.eta) end
  local lines = {head}
  for _, r in ipairs(st.irq) do
    local s = r.n <= (st.ack.n or 0) and 'acked' or (r.done == 1 and 'default' or (r.done == 2 and 'far' or 'unacked'))
    lines[#lines + 1] = string.format('%d\t%d\t%d\t%s\t%s\t%s', r.n, r.wall, r.tick, r.type, s,
                                      (tostring(r.msg):gsub('[\t\r\n]', ' ')))
  end
  return table.concat(lines, '\n') .. '\n'
end

-- <save>/alarm.txt, rewritten in place when anything in it changed (FR-53)
local function alarm_write(K, force)
  local dc = defcon(K)
  rt.defcon = dc
  local text = alarm_text(K, dc)
  local sig = text:gsub(' %(oldest %d+ s%)', '')   -- the age alone is no reason to rewrite the file
  if not force and sig == rt.alarm_sig then return end
  local path = tostring(K.cfg.paths and K.cfg.paths.save or '.') .. '/alarm.txt'
  local ok, err = fio.write(path, text)
  if ok then rt.alarm_sig = sig
  elseif not rt.alarm_warned then
    rt.alarm_warned = true
    K.log('warn', 'reflex: cannot write %s: %s', path, tostring(err))
  end
end

local function record(K, n, etype, msg, u)
  local now = K.now()
  st.irq[#st.irq + 1] = {n = n, type = etype, tick = now.tick, wall = now.wall, ms = now.ms,
                         msg = tostring(msg):sub(1, 200), done = 0, u = int(u)}
  while #st.irq > M.KEEP do table.remove(st.irq, 1) end
  dirty = true
  alarm_write(K, true)
end

-- emit a class-A interrupt and put it into alarm.txt in the same step
local function interrupt(K, etype, msg, d)
  local n = K.emit(etype, 'A', msg, d)
  if math.type(n) == 'integer' then record(K, n, etype, msg, type(d) == 'table' and d.id or nil) end
  return n
end

---------------------------------------------------------------- triggers
-- an arrival: lockdown (cfg defaults.ARRIVAL) and ARRIVAL (A, an interrupt) once per kind and lockdown
-- the caravans on the map (plotinfo.caravans with a trade state other than None), as entity id strings
local function caravans_here()
  local r = {}
  pcall(function()
    for _, c in ipairs(df.global.plotinfo.caravans) do
      local okn, s = pcall(function() return df.caravan_state.T_trade_state[c.trade_state] end)
      if not (okn and s == 'None') then r[#r + 1] = tostring(c.entity) end
    end
  end)
  return r
end

-- BUG-008 (Run 9: NO_DEPOT came again every few game days while the merchants waited, a few seconds apart at
-- timestream speed): one NO_DEPOT per caravan visit. st.depot = {ents = {<entity> = 1} of the visits already told,
-- rec = the cadence record}; a visit is forgotten once its caravan left the map. Without a readable caravan the
-- announcement counts as one visit of 'unknown', repeated only after max(7 game days, 10 min wall clock).
local function no_depot(K, text)
  local dep = st.depot or {ents = {}}
  st.depot = dep
  local cars = caravans_here()
  local here, new = {}, false
  for _, e in ipairs(cars) do
    here[e] = true
    if not dep.ents[e] then new = true end
  end
  local T = K.now()
  if #cars == 0 then
    if not CAD.elapsed(dep.rec, T) then return 'no depot reported' end
    here.unknown, new = true, true
  end
  if not new then return 'no depot reported' end
  for e in pairs(here) do dep.ents[e] = 1 end
  rt.dep_chk = T.tick
  dep.rec, dirty = CAD.mark(T, {}, {}), true
  interrupt(K, 'NO_DEPOT', 'caravan without a trade depot: ' .. tostring(text):sub(1, 140), {text = tostring(text):sub(1, 200)})
  return 'no depot reported'
end

-- a visit is forgotten once its caravan left the map (checked every DEPOT_EVERY ticks while one is remembered)
M.DEPOT_EVERY = 100
local function depot_visits(K, now)
  local dep = st.depot
  if not dep or next(dep.ents) == nil or now - (rt.dep_chk or -M.DEPOT_EVERY) < M.DEPOT_EVERY then return end
  rt.dep_chk = now
  local here = {}
  for _, e in ipairs(caravans_here()) do here[e] = true end
  for e in pairs(dep.ents) do
    if e ~= 'unknown' and not here[e] then dep.ents[e], dirty = nil, true end
  end
end

local function arrival(K, kind, src, text)
  local now = K.now().tick
  if kind == 'no_depot' then return no_depot(K, text) end
  local new = not (st.hold and st.hold.kinds[kind])
  local parts, d = engage(K, kind, 'arrival:' .. kind, cfg(K).defaults.ARRIVAL, now)
  if src ~= 'sighting' and st.hold then st.hold.fresh, dirty = now, true end   -- BUG-065: a news trigger, not the same intruder
  if new then
    d.kind, d.src, d.text = kind, src, tostring(text or ''):sub(1, 200)
    if rt.eta and rt.eta >= 0 then d.eta = rt.eta end
    -- what was done first, the announcement last (the text is cut at 200 bytes; d.text keeps it)
    local quoted = text and text ~= '' and ('; "' .. tostring(text):sub(1, 70) .. '"') or ''
    interrupt(K, 'ARRIVAL', compose(string.format('%s (%s) -> ', kind, src), parts, quoted), d)
  end
  return table.concat(parts, ', ')
end

-- public (K.call, arbiter FR-36): a threat or depot popup; the reflexes are issued before this returns, and the
-- arbiter dismisses the popup only after it. kind = siege|ambush|snatcher|beast|no_depot (arbiter's popup kinds)
function M.announce(K, kind, text, src)
  kind = tostring(kind or M.kind_of(text) or '')
  if kind == '' then return false end
  return true, arrival(K, kind, src or 'popup', text)
end

-- every step: the first armed hostile in sight (a visible invader, a great danger in reach of the fort). Run 11: the
-- listed invaders whose lockdown expired far do not count; one that came within lockdown_near again (far_scan) does
local function sighting(K, h, now)
  local inv = h.inv or 0
  if inv > 0 and next(rt.fset) then
    for _, e in ipairs(h.list or {}) do if e.k == 'inv' and rt.fset[e.id] then inv = inv - 1 end end
  end
  if inv > 0 then
    if not (st.hold and st.hold.kinds.invader) then
      local a = rt.appr and rt.appr.k == 'inv' and rt.appr
      arrival(K, 'invader', 'sighting', a and string.format('%s %d came within %s after its lockdown ended far', a.k,
                                                            a.id, a.what)
                                        or string.format('%d armed invaders in sight', inv))
    end
    return
  end
  if (h.great or 0) > 0 then
    local ok, a = K.call('threat', 'assess')
    if ok and type(a) == 'table' and (a.great_rel or 0) > 0 and not (st.hold and st.hold.kinds.beast) then
      arrival(K, 'beast', 'sighting', 'a great danger in reach')
    end
  end
end

-- INTRUDER / PREDATOR: a visible hostile on the citizens' walkable group (snapshot.far false; unknown counts as
-- the same group, fail-open); a wild danger counts only on a roofed tile (snapshot.outside_near r 0).
-- Intake waves and the sortie through O1 (Gordon 2026-10-16): while siege runs one (siege.expects), the hostiles
-- outside B1 are expected (sense zone 0 or 1: the soldiers in the killing field or outside share their walk group);
-- one past B1 (zone 2: Kern+, zones Z3/Z4) still counts
-- Run 11: an invader, undead or great danger whose lockdown expired far is no INTRUDER (it counts again once far_scan
-- finds it within lockdown_near); the INTRUDER names a near one first (far_scan) and comes again at once when one comes
-- near after an INTRUDER for far ones only (its ack timeout default skips a far unit)
local function inside_scan(K, h, now)
  local hostile, predator, nh, np, hnear = nil, nil, 0, 0, false
  local near, nf, far_one = cfg(K).predator_near, 0, nil
  local okx, expects = K.call('siege', 'expects')
  local wave = okx and expects == true
  for _, e in ipairs(h.list or {}) do
    local ok, far = true, false
    if (e.k ~= 'danger' or rt.hlset[e.id]) and rt.fset[e.id] then far = true
    elseif wave and (e.zn or 0) < 2 then far = true
    else ok, far = K.call('snapshot', 'far', e.x, e.y, e.z) end
    if not (ok and far == true) then
      if e.k == 'danger' then
        local oko, out = K.call('snapshot', 'outside_near', {{e.x, e.y, e.z}}, 0)
        if oko and type(out) == 'table' and out[1] == 0 then
          -- sense's dc: the distance to the nearest citizen outside Kern+ (-1 none); zone 2 = inside Kern+ / past B1
          local dc, lim = math.tointeger(e.dc), near
          if lim > 0 and dc and (e.zn or 0) < 2 and (dc < 0 or dc > lim) then
            nf = nf + 1
            if not far_one or (dc >= 0 and (far_one.dc < 0 or dc < far_one.dc)) then far_one = e end
          else np = np + 1; predator = predator or e end
        end
      else
        nh = nh + 1
        local a = rt.ap and rt.ap[e.id]
        local nr = not a or a.near == true or a.unknown == true
        if not hostile or (nr and not hnear) then hostile, hnear = e, nr end
      end
    end
  end
  if hostile then
    if now - (rt.intr_last or -M.REARM) >= M.REARM or (hnear and not rt.intr_near) then
      local a = rt.ap and rt.ap[hostile.id]
      local dist = a and a.d or -1
      interrupt(K, 'INTRUDER', string.format('%d hostiles on the citizens\' walkable group (%s %d at %d,%d,%d%s)', nh,
                hostile.k, hostile.id, hostile.x, hostile.y, hostile.z,
                hnear and '' or string.format('; far: %d tiles from the citizens and entrances', dist)),
                {n = nh, id = hostile.id, pos = {hostile.x, hostile.y, hostile.z}, k = hostile.k, dist = dist,
                 far = hnear and 0 or 1})
      rt.intr_near = hnear
    end
    rt.intr_last = now
  end
  if far_one and not predator and now - (rt.pfar_last or -M.REARM) >= M.REARM then
    -- class B only: no lockdown, no clock hold for an animal far from every citizen (Run 10)
    rt.pfar_last = now
    K.emit('PREDATOR_FAR', 'B', string.format('%d wild dangers on the citizens\' walkable group but far from the citizens '
           .. '(%d at %d,%d,%d, %s): no lockdown', nf, far_one.id, far_one.x, far_one.y, far_one.z,
           (math.tointeger(far_one.dc) or -1) >= 0 and ('nearest citizen ' .. far_one.dc .. ' tiles') or 'no citizen outside Kern+'),
           {n = nf, id = far_one.id, pos = {far_one.x, far_one.y, far_one.z}, dc = math.tointeger(far_one.dc) or -1})
  end
  if predator then
    if now - (rt.pred_last or -M.REARM) >= M.REARM then
      interrupt(K, 'PREDATOR', string.format('%d wild dangers inside the fort (%d at %d,%d,%d)', np, predator.id,
                predator.x, predator.y, predator.z), {n = np, id = predator.id, pos = {predator.x, predator.y, predator.z}})
    end
    rt.pred_last = now
  end
end

-- FR-58: ticks until the nearest visible invader or great danger could reach the nearest entrance; -1 unknown
local function eta(K, h, now)
  local pts = {}
  local okg, gp = K.call('gate', 'points')
  for _, p in ipairs(okg and type(gp) == 'table' and gp or {}) do pts[#pts + 1] = p end
  for _, d in ipairs(rt.door_pts or rt.doors and rt.doors.list or {}) do
    pts[#pts + 1] = {x = d.pos[1], y = d.pos[2], z = d.pos[3]}
  end
  local best = -1
  if #pts > 0 then
    for _, e in ipairs(h.list or {}) do
      if (e.k == 'inv' or e.k == 'great') and not (e.k == 'inv' and rt.fset[e.id]) then
        for _, p in ipairs(pts) do
          local dd = geom.dist(e, p)
          if best < 0 or dd < best then best = dd end
        end
      end
    end
  end
  rt.eta = best >= 0 and best * M.ETA_TILE or -1
end

-- the deferred civ alert of a lockdown (alert_due): on once no lever pull is pending, at the deadline, or when a
-- hostile comes near. Afterwards, while pulls are left, a pull the alert blocks (its levers outside every alert
-- burrow: no lever burrow) is logged once per change (BUG-013)
M.PULL_POLL = 50           -- ticks between two looks at the pulls left once the alert sounds
local function alert_step(K, now)
  local hd = st.hold
  if not (hd and hd.acts.alert) then return end
  if not hd.alert_on then
    local why, p = alert_due(K, hd, now)
    if not why then
      alert_deadline(hd, now, p)
      return
    end
    hd.alert_on, hd.alert_t, dirty = true, now, true
    local okc, r = K.call('siege', 'hold_alert')
    K.log('info', 'reflex: civ alert: %s (%s)%s', okc and tostring(r) or 'none (no siege module)', why,
          p and hd.acts.gates and ('; ' .. gates_text(p)) or '')
    recall_start(K, hd, now)
    rt.pull_t = now
    return
  end
  if not hd.acts.gates or rt.pull_sig == 'done' or now - (rt.pull_t or -M.PULL_POLL) < M.PULL_POLL then return end
  rt.pull_t = now
  local p = pulls(K)
  if not p then return end
  local sig = (int(p.left) or 0) == 0 and 'done' or ((int(p.left) or 0) .. '/' .. (int(p.out) or 0))
  if sig ~= rt.pull_sig and sig ~= 'done' then
    K.log((int(p.out) or 0) > 0 and 'warn' or 'info', 'reflex: alert on, %s', gates_text(p))
  end
  rt.pull_sig = sig
end

-- BUG-012: while a lockdown holds the doors, a new answer of seal's entrance check (the fresh check the lockdown
-- asked for, a lever pull, a construction) may name doors not forbidden yet; they are forbidden at once
-- and the doors still waiting for citizens outside (BUG-015: and the refused ones with a retry left) are looked at
-- every DOOR_POLL ticks
local function door_step(K, now)
  local hd = st.hold
  if not (hd and hd.acts.doors) then return end
  local x = seal_doors(K, false)
  local news = x and x.tick ~= rt.seal_tick
  local poll = rt.wait and #rt.wait > 0 and (now - (rt.wait_t or now) >= M.DOOR_POLL or now < (rt.wait_t or now))
  -- BUG-015: a refused door with its retry left is looked at every DOOR_POLL ticks (retry_due)
  local retry = false
  for _, r in ipairs(st.ref) do if r.try == 1 then retry = true; break end end
  retry = retry and (now - (rt.ref_t or -M.DOOR_POLL) >= M.DOOR_POLL or now < (rt.ref_t or now))
  if not (news or poll or retry or (rt.wait == nil and hd.doors_at)) then return end
  if retry then rt.ref_t = now end
  local s, n = forbid_doors(K, now, false)
  if n > 0 then K.log('info', 'reflex: %d more entrance doors forbidden: %s', n, s) end
end

-- BUG-065: why the quiet clock does not run (nil = it runs). One decision for quiet_step, the state (alarm.qw) and the
-- confinement limit: stale (no fresh census), inside (a hostile inside Kern+), near (a visible invader that is not
-- far), great (a great danger in reach), recent (a trigger in the last ARM ticks), armed (threat's scan window)
local function quiet_block(K, h, now)
  local hd = st.hold
  local fresh = type(h) == 'table' and now - (h.tick or -1e9) <= M.FRESH
  if not fresh then return 'stale' end
  if (h.inside or 0) > 0 then return 'inside' end
  if (h.inv or 0) > 0 and not far_now(K, h) then return 'near' end
  if (h.great or 0) > 0 then
    local ok, a = K.call('threat', 'assess')
    if not (ok and type(a) == 'table' and (a.great_rel or 0) == 0) then return 'great' end
  end
  if now - hd.last < M.ARM then return 'recent' end
  local ok, armed = K.call('threat', 'armed')
  if ok and armed == 1 then return 'armed' end
  return nil
end

-- the quiet clock: no visible invader, great danger in reach or hostile inside, threat not armed, ARM after the
-- last trigger; hold_quiet_days of it end the lockdown. Run 11: in PEACE/ALERT visible invaders do not stop it while
-- each one is listed and beyond lockdown_near of every citizen outside Kern+ and every entrance (far_now)
local function quiet_step(K, h, now)
  local hd = st.hold
  if not hd then return end
  local why = quiet_block(K, h, now)
  rt.qw = why or 'run'
  if why then
    if hd.qs then hd.qs, dirty = nil, true end
    return
  end
  if not hd.qs then hd.qs, dirty = now, true end
  if now - hd.qs >= cfg(K).hold_quiet_days * 1200 then release(K, now) end
end

---------------------------------------------------------------- BUG-065: the confinement limit, the offer, the need
M.CF_EVERY = 100           -- ticks between two looks at the confinement limit
M.NEED_EVERY = 300         -- ticks between two looks at the citizens in need behind the alert
M.NEED_SLICE = 60          -- citizens looked at per look (a bigger fort takes several looks)

-- is census entry e a harmless intruder? Never a great danger, undead, building destroyer, large predator, trap avoider
-- or flier; small (its own body size up to confine.harmless_size, cm3: a dwarf is 60000) or a race of confine.harmless_races.
-- An unreadable size is no evidence (not harmless)
local function harmless(e, c)
  if e.k == 'great' or e.k == 'undead' or e.dz == 1 or e.bd or e.pr then return false end
  local sz = int(e.sz)
  if sz and c.harmless_size > 0 and sz <= c.harmless_size then return true end
  if #c.harmless_races > 0 then
    local r = race_of(e.id):upper():gsub('[^%w]+', '_')
    for _, v in ipairs(c.harmless_races) do if v == r then return true end end
  end
  return false
end

-- the counted hostiles of the fresh census (not expired far, not cleared): near = inside Kern+, within lockdown_near or
-- of unknown distance. Returns {near = {ap}, dangerous = the first near one that is not a harmless lone intruder (or the
-- list was cut: unknown ones may be dangerous) | nil}, nil without a fresh far scan
local function confine_picture(K, h)
  if type(h) ~= 'table' or not rt.ap or rt.ftick ~= h.tick then return nil end
  local c = cfg(K).confine
  local near, danger = {}, nil
  for _, e in ipairs(h.list or {}) do
    local a = rt.ap[e.id]
    if a and not rt.fset[e.id] and (a.near or a.unknown) then
      near[#near + 1] = a
      if not danger and not harmless(e, c) then danger = a end
    end
  end
  if not danger and #near > c.lone_max then danger = near[1] end
  if not danger and (h.vis or 0) > #(h.list or {}) then danger = near[1] or {e = {}, d = -1} end
  return {near = near, dangerous = danger}
end

-- the picture when the lockdown may be ended on it: PEACE/ALERT, a fresh census, no news trigger in the last ARM ticks,
-- threat not armed
local function calm_picture(K, h, now)
  local hd = st.hold
  if not hd or not FAR_MODES[K.mode()] then return nil end
  if type(h) ~= 'table' or now - (h.tick or -1e9) > M.FRESH then return nil end
  if now - (hd.fresh or hd.since) < M.ARM then return nil end
  local ok, armed = K.call('threat', 'armed')
  if ok and armed == 1 then return nil end
  local pic = confine_picture(K, h)
  if not pic then return nil end
  -- a great danger in reach, an undead wave, a siege-sized army or an armed invasion is dangerous at any distance
  local oka, a = K.call('threat', 'assess')
  if not (oka and type(a) == 'table') then return nil end
  if (a.great_rel or 0) > 0 or a.siege then pic.dangerous = pic.dangerous or pic.near[1] or {e = {}, d = -1} end
  return pic
end

-- the cause shown by state/status/brief: the nearest counted hostile (near first, then by distance)
local function cause_scan(K, h)
  rt.cause = nil
  if not st.hold or type(h) ~= 'table' or not rt.ap or rt.ftick ~= h.tick then return end
  local c = cfg(K).confine
  local best, n = nil, 0
  for _, e in ipairs(h.list or {}) do
    local a = rt.ap[e.id]
    if a and not rt.fset[e.id] then
      n = n + 1
      local rank = a.near and 0 or (a.unknown and 1 or 2)
      local d = a.d >= 0 and a.d or 1e9
      if not best or rank < best.rank or (rank == best.rank and (d < best.dd or (d == best.dd and e.id < best.a.e.id))) then
        best = {rank = rank, dd = d, a = a}
      end
    end
  end
  if best then
    local e = best.a.e
    rt.cause = {id = e.id, k = e.an == 1 and 'animal' or e.k, pos = {e.x, e.y, e.z}, dc = best.a.dc, de = best.a.de,
                hl = harmless(e, c) and 1 or 0, n = n, near = best.a.near == true, sz = int(e.sz)}
    local rc = rt.cause_race
    if not rc or rc.id ~= e.id then rc = {id = e.id, race = race_of(e.id)}; rt.cause_race = rc end
    rt.cause.race = rc.race:upper():gsub('[^%w]+', '_'):sub(1, 24)
  end
end

local function tiles_txt(d, what) return d >= 0 and string.format('%d tiles from %s', d, what) or nil end

-- one sentence for the cause of the lockdown: 'inv 300 GREMLIN (size 4000) at 110,20,10, 10 tiles from a citizen outside
-- Kern+, 58 from an entrance'
local function cause_txt(cs)
  local l = {string.format('%s %d %s%s at %d,%d,%d', cs.k, cs.id, cs.race, cs.sz and string.format(' (size %d)', cs.sz) or '',
                           cs.pos[1], cs.pos[2], cs.pos[3])}
  l[#l + 1] = tiles_txt(cs.dc, 'a citizen outside Kern+')
  l[#l + 1] = tiles_txt(cs.de, 'an entrance')
  return table.concat(l, ', ')
end

-- the way out the report offers: squad.sortie to the unit's position with the squad military names
local function sortie_cmd(K, cs)
  local ok, key, n = K.call('military', 'sortie_squad')
  if not (ok and type(key) == 'string') then return nil, nil, 0 end
  return string.format('dfllm cmd squad.sortie \'{"squad":"%s","target":[%d,%d,%d],"approve":true}\'', key, cs.pos[1],
                       cs.pos[2], cs.pos[3]), key, int(n) or 0
end

-- DECISION_NEEDED intruder_sortie (A): a harmless intruder that holds the lockdown (after offer_days) or a dangerous one
-- past the limit; once per episode and unit (CAD.due: a repeat needs another unit or a changed cause)
local function offer_step(K, h, now)
  local hd, cs = st.hold, rt.cause
  if not hd or not cs or not cs.near or K.mode() ~= 'ALERT' then return end
  local c = cfg(K).confine
  local age = now - hd.since
  local lim = c.max_days * 1200
  if cs.hl == 1 then
    if age < c.offer_days * 1200 then return end
  elseif lim <= 0 or age < lim then
    return
  end
  local T = K.now()
  local rec = st.cf and st.cf.o
  -- review C1: a repeat needs news (another unit, or harmless -> dangerous), never the same offer every offer_days for as
  -- long as a dangerous intruder keeps the lockdown (BUG-008's rule for standing class-A conditions)
  local tok = cs.hl == 1 and 'harmless' or 'dangerous'
  if not CAD.due(rec, T, {cs.id}, {tok}, {ticks = math.max(1, c.offer_days) * 1200, wall_s = 60}) then return end
  local cmd, key, n = sortie_cmd(K, cs)
  local days = string.format('%.1f', age / 1200)
  local q
  if cs.hl == 1 then
    q = string.format('harmless lone intruder %s holds the lockdown %s for %s days (it ends by itself after %d): %s',
                      cause_txt(cs), hd.why, days, c.max_days,
                      cmd and string.format('send squad %s (%d soldiers): %s', key, n, cmd) or
                      'no squad to send; wait for the limit')
  else
    q = string.format('dangerous %s keeps the lockdown %s for %s days (limit %d days, it stays while this one is near): %s',
                      cause_txt(cs), hd.why, days, c.max_days,
                      cmd and string.format('squad %s (%d soldiers) could go if it is strong enough: %s', key, n, cmd) or
                      'no squad to send')
  end
  st.cf = st.cf or {}
  st.cf.o, dirty = CAD.mark(T, {cs.id}, {tok}), true
  -- J3: d.q is at most 200 bytes (schema.py; the command is d.cmd), the log keeps the whole sentence
  local d = {id = 'intruder_sortie', q = q:sub(1, 200), unit = cs.id, pos = cs.pos, race = cs.race, hl = cs.hl, dc = cs.dc,
             de = cs.de, age = age, lim = lim}
  if cmd then d.squad, d.cmd = key, cmd end
  K.emit('DECISION_NEEDED', 'A', q, d)
  K.log('info', 'reflex: %s', q)
end

-- the lockdown's own clock: confine.max_days after it began it ends in PEACE/ALERT unless a dangerous hostile is near
local function confine_step(K, h, now)
  local hd = st.hold
  if not hd then return end
  local c = cfg(K).confine
  if c.max_days <= 0 or now - hd.since < c.max_days * 1200 then return end
  if rt.cf_t and now >= rt.cf_t and now - rt.cf_t < M.CF_EVERY then return end
  rt.cf_t = now
  local pic = calm_picture(K, h, now)
  if pic and not pic.dangerous then release(K, now, 'limit', pic) end
end

-- a mood dwarf or a patient behind the sounding alert over confine.need_thirst / need_hunger: DECISION_NEEDED
-- confined_need (CAD) and, with nothing dangerous near, the lockdown ends for him. Soldiers and children are looked at
-- like the rest; the siege module's relax path (STRANDED) stays the rescue for the others
local function need_step(K, h, now)
  local WHO = require('dfllm.util.who')
  local hd = st.hold
  if not hd or not FAR_MODES[K.mode()] then return end
  if rt.nd_t and now >= rt.nd_t and now - rt.nd_t < M.NEED_EVERY then return end
  rt.nd_t = now
  local okc, civ = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  if not (okc and civ ~= nil and civ ~= 0) then return end
  local cu = K.census.u
  local ids = type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}
  local c = cfg(K).confine
  local who = {}
  local from = (rt.nd_i or 0) % math.max(1, #ids)
  for k = 1, math.min(#ids, M.NEED_SLICE) do
    local id = ids[(from + k - 1) % #ids + 1]
    local u = df.unit.find(id)
    -- BUG-103: the census holds residents too; a resident or a merchant confined by nothing of ours is no case for
    -- confined_need (and never a reason to end the lockdown)
    if u and WHO.citizen(u) then
      local th = try(function() return u.counters2.thirst_timer end) or 0
      local hu = try(function() return u.counters2.hunger_timer end) or 0
      if th >= c.need_thirst or hu >= c.need_hunger then
        local why
        if (try(function() return u.mood end) or -1) >= 0 then why = 'mood'
        elseif try(function() return u.health.flags.needs_healthcare end) == true then why = 'patient'
        else
          local j = try(function() return u.job.current_job end)
          if j ~= nil and try(function() return j.job_type == df.job_type.Rest end) == true then why = 'patient' end
        end
        if why then who[#who + 1] = {id = id, why = why, th = int(th) or 0, hu = int(hu) or 0} end
      end
    end
  end
  rt.nd_i = from + M.NEED_SLICE
  if #who == 0 then return end
  table.sort(who, function(p, q) return p.id < q.id end)
  local T = K.now()
  local idl, toks = {}, {}
  for _, w in ipairs(who) do idl[#idl + 1] = w.id; toks[#toks + 1] = w.why end
  local pic = calm_picture(K, h, now)
  local end_it = pic and not pic.dangerous
  local rec = st.cf and st.cf.n
  if not CAD.due(rec, T, idl, toks, {ticks = 1200, wall_s = 60}) and not end_it then return end
  local w1 = who[1]
  local q = string.format('%s %d is confined by the lockdown %s (thirst %d, hunger %d; %d in need): %s', w1.why, w1.id,
                          hd.why, w1.th, w1.hu, #who,
                          end_it and 'nothing dangerous is near, the lockdown ends for him'
                          or (rt.cause and ('kept by ' .. cause_txt(rt.cause) .. '; STRANDED relax is the rescue for the '
                              .. 'others, a sortie clears the cause') or 'a trigger is recent, it ends by itself'))
  st.cf = st.cf or {}
  st.cf.n, dirty = CAD.mark(T, idl, toks), true
  local units = {}
  for i = 1, math.min(#idl, 10) do units[i] = idl[i] end
  K.emit('DECISION_NEEDED', 'A', q, {id = 'confined_need', q = q:sub(1, 200), unit = w1.id, units = units, why = w1.why,
                                      thirst = w1.th, hunger = w1.hu, n = #who})
  K.log('warn', 'reflex: %s', q)
  if end_it then release(K, now, 'need', pic, who) end
end

-- BUG-108 (Run 14 note 88): threat 0 = a fresh census that shows no hostile at all (not one far away, none inside, no
-- invader) and a threat scan that is not armed. Anything else (a stale reading, no census) is not threat 0.
local function threat_zero(K)
  local h = K.census.h
  if type(h) ~= 'table' or K.now().tick - (int(h.tick) or -1e9) > M.FRESH then return false end
  if (int(h.vis) or 0) > 0 or (int(h.inv) or 0) > 0 or (int(h.inside) or 0) > 0 then return false end
  local ok, armed = K.call('threat', 'armed')
  return not (ok and armed == 1)
end

-- ack timeout: an interrupt unacked for ack_timeout_s gets its type's lockdown default, and LOCKDOWN (A) says so.
-- BUG-108: an inner-cause interrupt (cfg inner: DEATHS_3PLUS) at threat 0 gets none: the event woke the player, and a
-- clock clamp or civ alert for a cause no enemy shares (patients, moods, a curse) only slows the fort and sends the
-- carers away from the hospital
local function ack_step(K, now)
  local c = cfg(K)
  local ms = K.now().ms
  for _, r in ipairs(st.irq) do
    if ms < r.ms then r.ms, dirty = ms, true end     -- the real-time clock restarted (reboot): count again
    local age = (ms - r.ms) // 1000
    if r.n > (st.ack.n or 0) and r.done == 0 and age >= c.ack_timeout_s then
      r.done, dirty = 1, true
      local acts = c.defaults[r.type] or {}
      -- Run 11: no default for an INTRUDER/PREDATOR whose unit is far now (expired far, or listed beyond lockdown_near):
      -- the same far unit never re-applies the lockdown; it re-arms once it comes within lockdown_near
      local far = #acts > 0 and (r.type == 'INTRUDER' or r.type == 'PREDATOR') and unit_far(K, r.u)
      if far then
        r.done = 2
        K.log('info', 'reflex: interrupt #%d %s unacked for %d s; its unit %d is far (%s, lockdown_near %d): no default',
              r.n, r.type, age, r.u, far, c.lockdown_near)
      elseif #acts == 0 then
        K.log('info', 'reflex: interrupt #%d %s unacked for %d s; no default action', r.n, r.type, age)
      elseif c.inner[r.type] and threat_zero(K) then
        r.done = 2
        K.log('info', 'reflex: interrupt #%d %s unacked for %d s; inner cause at threat 0: no lockdown default, no ' ..
              'civ alert (reflex.inner)', r.n, r.type, age)
      else
        local parts, d = engage(K, 'unacked', 'unacked:' .. r.type, acts, now)
        d.why, d.n, d.type = 'ack_timeout', r.n, r.type
        K.emit('LOCKDOWN', 'A', compose(string.format('interrupt #%d %s unacked for %d s: kernel applied its default: ',
               r.n, r.type, age), parts), d)
      end
      alarm_write(K, true)
    end
  end
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.reflex')
  st = {v = 2, doors = {}, ack = {n = 0, wall = 0}, irq = {}, vfy = {}, ref = {}, far = {t = 0, ids = {}, hl = {}}}
  if type(p) == 'table' then
    for _, id in ipairs(type(p.doors) == 'table' and p.doors or {}) do
      if int(id) then st.doors[#st.doors + 1] = int(id) end
    end
    -- BUG-015: doors not read back yet and refused doors survive a reload
    local function pos3(q) return type(q) == 'table' and int(q[1]) and int(q[2]) and int(q[3]) and
                                  {int(q[1]), int(q[2]), int(q[3])} or nil end
    for _, v in ipairs(type(p.vfy) == 'table' and p.vfy or {}) do
      local q = type(v) == 'table' and int(v.id) and pos3(v.pos)
      if q then st.vfy[#st.vfy + 1] = {id = int(v.id), t = int(v.t) or 0, try = int(v.try) == 2 and 2 or 1, pos = q} end
    end
    for _, r in ipairs(type(p.ref) == 'table' and p.ref or {}) do
      local q = type(r) == 'table' and int(r.id) and pos3(r.pos)
      if q then
        st.ref[#st.ref + 1] = {id = int(r.id), t = int(r.t) or 0, try = int(r.try) == 2 and 2 or 1, pos = q,
                               sig = tostring(r.sig or ''), items = int(r.items) or 0, units = int(r.units) or 0}
      end
    end
    if type(p.prec) == 'table' then st.prec = p.prec end
    if type(p.ack) == 'table' then st.ack = {n = int(p.ack.n) or 0, wall = int(p.ack.wall) or 0} end
    for _, r in ipairs(type(p.irq) == 'table' and p.irq or {}) do
      if type(r) == 'table' and int(r.n) and type(r.type) == 'string' then
        st.irq[#st.irq + 1] = {n = int(r.n), type = r.type, tick = int(r.tick) or 0, wall = int(r.wall) or 0,
                               ms = int(r.ms) or K.now().ms, msg = tostring(r.msg or ''),
                               done = (int(r.done) == 1 or int(r.done) == 2) and int(r.done) or 0, u = int(r.u)}
      end
    end
    local dp = p.depot
    if type(dp) == 'table' and type(dp.ents) == 'table' then
      st.depot = {ents = {}, rec = type(dp.rec) == 'table' and {t = int(dp.rec.t), w = int(dp.rec.w)} or nil}
      for e, v in pairs(dp.ents) do if v == 1 then st.depot.ents[tostring(e)] = 1 end end
    end
    local h = p.hold
    if type(h) == 'table' and type(h.why) == 'string' then
      st.hold = {why = h.why, kinds = {}, acts = {}, since = int(h.since) or 0, last = int(h.last) or 0, qs = nil,
                 alert_on = h.alert_on == true, alert_at = int(h.alert_at), doors_at = int(h.doors_at),
                 alert_t = int(h.alert_t), wait = int(h.wait), fresh = int(h.fresh)}
      for k, v in pairs(type(h.kinds) == 'table' and h.kinds or {}) do if v == true then st.hold.kinds[k] = true end end
      for k, v in pairs(type(h.acts) == 'table' and h.acts or {}) do if v == true then st.hold.acts[k] = true end end
      local rc = h.rc                                      -- Run 11: an open recall survives a reload
      if type(rc) == 'table' and int(rc.t) and int(rc.n) then
        local ids = {}
        for _, id in ipairs(type(rc.ids) == 'table' and rc.ids or {}) do
          if int(id) and #ids < M.RECALL_IDS then ids[#ids + 1] = int(id) end
        end
        local to = {}                                      -- BUG-035: the burrows it measures arrival in
        for _, n in ipairs(type(rc.to) == 'table' and rc.to or {}) do
          if type(n) == 'string' and #to < 4 then to[#to + 1] = n end
        end
        st.hold.rc = {t = int(rc.t), n = int(rc.n), ids = ids, left = int(rc.left) or int(rc.n), eta = int(rc.eta) or -1,
                      called = rc.called == true, burrow = type(rc.burrow) == 'string' and rc.burrow or nil,
                      late = int(rc.late), done = int(rc.done), to = to, nnew = int(rc.nnew) or 0,
                      stuck = int(rc.stuck) or 0, pull = int(rc.pull) or 0, rep = int(rc.rep)}
      end
    end
    -- Run 11: the hostiles a lockdown expired far stay so across a reload
    local f = p.far
    if type(f) == 'table' and type(f.ids) == 'table' then
      st.far.t = int(f.t) or 0
      for _, id in ipairs(f.ids) do
        if int(id) and #st.far.ids < M.FAR_MAX then st.far.ids[#st.far.ids + 1] = int(id) end
      end
      local inf = {}
      for _, id in ipairs(st.far.ids) do inf[id] = true end
      for _, id in ipairs(type(f.hl) == 'table' and f.hl or {}) do      -- BUG-065: the cleared harmless intruders
        if int(id) and inf[int(id)] then st.far.hl[#st.far.hl + 1] = int(id) end
      end
    end
    local cf = p.cf                                      -- BUG-065: the offer and need cadences
    if type(cf) == 'table' then
      local function rec(r)
        if type(r) ~= 'table' or not int(r.t) then return nil end
        local o = {t = int(r.t), w = int(r.w), ids = {}, toks = {}}
        for _, v in ipairs(type(r.ids) == 'table' and r.ids or {}) do if int(v) then o.ids[#o.ids + 1] = int(v) end end
        for _, v in ipairs(type(r.toks) == 'table' and r.toks or {}) do if type(v) == 'string' then o.toks[#o.toks + 1] = v end end
        return o
      end
      st.cf = {o = rec(cf.o), n = rec(cf.n)}
    end
  end
  rt, dirty = {}, false
  far_set()
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local h = K.census.h
  local fresh = type(h) == 'table' and now - (h.tick or -1e9) <= M.FRESH
  -- the open-sky door scan first: Run 11's far_scan measures the hostiles to those doors too
  if not rt.doors or now - rt.doors.tick >= M.DOOR_EVERY or now < rt.doors.tick then entrance_doors(K, now) end
  if fresh and h.tick ~= rt.htick then
    rt.htick = h.tick
    if rt.ftick ~= h.tick then far_scan(K, h, now) end      -- Run 11 (threat may have asked far_ids first)
    eta(K, h, now)                                          -- Run 11: the first sighting's ARRIVAL and recall carry it
    sighting(K, h, now)
    inside_scan(K, h, now)
    rt.appr = nil
  end
  alert_step(K, now)
  recall_step(K, now)                                      -- Run 11: before the doors (late lets them close)
  verify_doors(K, now)
  door_step(K, now)
  quiet_step(K, h, now)
  cause_scan(K, h)                                         -- BUG-065: the cause for state/status, then the limit
  offer_step(K, h, now)
  confine_step(K, h, now)
  need_step(K, h, now)
  ack_step(K, now)
  depot_visits(K, now)
  alarm_write(K)
  save(K)
end

M.on = {
  INVASION = function(K, ev)
    arrival(K, 'invasion', 'invasion', string.format('invasion %d', int(ev.id) or -1))
    alarm_write(K)
  end,
  REPORT = function(K, ev)
    local kind = M.kind_of(ev.text) or REPORT_KIND[ev.type]
    if kind then arrival(K, kind, 'report', ev.text ~= '' and ev.text or ev.type) end
  end,
  ['EV:DEATHS_3PLUS'] = function(K, ev)
    record(K, ev.n, ev.type, ev.msg)
    save(K)
  end,
  MODE = function(K, ev)
    -- Run 11 (siege 8: 7 citizens still outside at the breach): the recall's state when the fight begins or breaks in
    local h = st.hold
    local rc = h and h.rc
    if rc and not rc.done and (ev.to == 'SIEGE' or ev.to == 'BREACH') then
      local now = K.now().tick
      local m = recall_step(K, now, true) or rt.rm
      if not rc.done then
        local l = tokens(m and m.still or {}, 6)
        K.log('warn', 'reflex: recall: %d of %d citizens still outside %s at the %s, %d ticks after the alert (%s)%s',
              rc.left or rc.n, rc.n, rc_where(K, rc), ev.to, now - rc.t, #l > 0 and table.concat(l, ' ') or '?',
              (rc.nnew or 0) > 0 and string.format('; +%d more out since', rc.nnew) or '')
      end
    end
    alarm_write(K)
  end,
}

-- verb `ack {n?}`: the operator saw the interrupts up to n (default: all); the timeout default no longer applies
M.verbs.ack = function(K, args, cmd)
  local last = st.irq[#st.irq] and st.irq[#st.irq].n or 0
  local n = args.n == nil and last or int(args.n)
  if not n or n < 0 then return false, 'n must be an event number >= 0' end
  if n > (st.ack.n or 0) then st.ack = {n = n, wall = K.now().wall}; dirty = true end
  local open = unacked(K)
  alarm_write(K, true)
  save(K)
  return true, string.format('acked up to #%d (%d interrupts open, DEFCON %d)', st.ack.n, open, rt.defcon or 5),
         {n = st.ack.n, open = open, defcon = rt.defcon or 5}
end

function M.state(K)
  local open = unacked(K)
  local a = {defcon = rt.defcon or defcon(K), unacked = open, last = st.irq[#st.irq] and st.irq[#st.irq].n or 0,
             ack = st.ack.n or 0, lock = st.hold and 1 or 0, why = st.hold and st.hold.why:sub(1, 24) or ''}
  if rt.eta then a.eta = rt.eta end
  if st.hold and st.hold.acts.doors then           -- the lockdown's doors: forbidden, waiting, citizens outside
    a.doors = #st.doors
    if rt.wait and #rt.wait > 0 then a.dwait, a.dout = #rt.wait, rt.wait_out or 0 end
    local nref = #refused_now()
    if nref > 0 then a.dref = nref end              -- BUG-015: refused, the flag fell back
  end
  local rc = st.hold and st.hold.rc                 -- BUG-035: the recall: called, still out, left since, cannot come
  if rc and rc.called and not rc.done then
    a.rn, a.rleft, a.rnew, a.rstuck = rc.n, rc.left or rc.n, rc.nnew or 0, rc.stuck or 0
    a.rto = rc_where(K, rc):sub(1, 24)
  end
  if #st.far.ids > 0 then a.far = #st.far.ids end   -- Run 11: hostiles whose lockdown expired far
  if st.hold then                                    -- BUG-065: the lockdown's age, its limit, why it holds, its cause
    local now = K.now().tick
    a.age = math.max(0, now - st.hold.since)
    a.lim = cfg(K).confine.max_days * 1200
    a.qw = rt.qw or 'stale'
    local cs = rt.cause
    if cs then
      a.by = {id = cs.id, race = cs.race, k = cs.k, pos = cs.pos, dc = cs.dc, de = cs.de, hl = cs.hl, n = cs.n, sz = cs.sz}
    end
  end
  return {alarm = a}
end

return M
