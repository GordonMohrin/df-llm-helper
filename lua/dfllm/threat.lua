-- threat (WP5): arming and classification (DESIGN §3 mode table, §4 siege reflex).
-- onInvasion only ARMS the fast scan (the army may still be hidden); reports arm it too.
-- assess() turns the visible-only census K.census.h into the siege FSM inputs.
-- WP5-internal calls (K.call): threat.armed() -> 0|1, until; threat.assess() -> table|nil.
--
-- Reach. Invaders count map-wide (DESIGN §4: RECOVERY needs 0 visible invaders map-wide). Every
-- other hostile (wildlife danger, undead, great danger) counts only if it can plausibly reach the
-- fort: within REACH tiles (xy) of a manifest bridge footprint and on the fortcore's z band
-- (deepest bridge/refuge - BAND_BELOW .. highest bridge + BAND_ABOVE), or within CIT_NEAR of a
-- citizen outside Kern+, or inside Kern+. A forgotten beast in a revealed but sealed cavern or a
-- titan at the far map edge therefore never locks the fort in SIEGE/ALERT; a visible great danger
-- out of reach is reported once as DECISION_NEEDED (A) instead. Entry uses REACH, quiet/calm use
-- REACH_QUIET (hysteresis), so entry, RECOVERY re-entry and quiet agree.
-- Run 11 (site98 y439: one ELK_BIRD invader, a mount left behind at the map edge, kept ALERT for 45 days):
--   * an invader sense lists as an animal (an = 1, k 'danger') counts by the predator rule only: inside Kern+ / past B1
--     (zone 2) or within reflex.predator_near (config/reflex.json, 40; 0 = the danger reach rule) of a citizen outside
--     Kern+;
--   * the hostiles reflex lists as expired far (reflex.far_ids: a lockdown ended after hold_quiet_days without one of
--     them coming within reflex.lockdown_near of a citizen or an entrance) count for nothing (inv, reach, calm, quiet)
--     until one comes that close (reflex drops it from the list then), so ALERT ends with the lockdown.
local M = {name = 'threat', every = {ticks = 25}, critical = true,
           reports = {UNDEAD_ATTACK = true, NIGHT_ATTACK_STARTS = true, MEGABEAST_ARRIVAL = true,
                      WEREBEAST_ARRIVAL = true, BEAST_AMBUSH = true, AMBUSH_AMBUSHER = true,
                      AMBUSH_THIEF = true, AMBUSH_SNATCHER = true}}

M.ARM = 2400          -- ticks a trigger keeps the fast scan armed (CONTRACTS §6.2)
M.SIEGE_INV = 6       -- visible invaders that make a SIEGE on their own
M.NEAR_O1 = 40        -- RECOVERY needs 0 visible dangers this close to O1
M.FRESH = 200         -- census.h older than this is "unknown" (never quiet)
M.REACH, M.REACH_QUIET = 100, 120  -- xy tiles from a bridge footprint: entry / quiet (hysteresis);
                                    -- a 3x3 embark is 144 wide, so this mainly cuts caverns and far corners
M.BAND_BELOW, M.BAND_ABOVE = 3, 40 -- z band around the fortcore levels
M.CIT_NEAR = 40       -- a hostile this close to a citizen outside Kern+ always counts
-- Run 11: an explore shaft open to a cavern (runner.cavern_open, until its plug wall stands) is a way in below the z
-- band: a hostile within SHAFT_R tiles (xy) of the shaft, from SHAFT_DZ levels below its bottom up to its top, counts
M.SHAFT_R, M.SHAFT_DZ = 30, 5

-- report type -> window: inv (counts like INVASION for the SIEGE rule), undead, scan (fast scan only)
local REPORT_WINDOW = {UNDEAD_ATTACK = 'undead', NIGHT_ATTACK_STARTS = 'undead', AMBUSH_AMBUSHER = 'inv',
                       AMBUSH_THIEF = 'inv', AMBUSH_SNATCHER = 'inv', MEGABEAST_ARRIVAL = 'scan',
                       WEREBEAST_ARRIVAL = 'scan', BEAST_AMBUSH = 'scan'}

local st                 -- persisted as m.threat: {v, inv, undead, scan} = abs tick each window ends
local seen_inv = {}      -- invasion ids already reported this session
local far_seen = {}      -- great dangers already reported as out of reach this session
local pub                -- precomputed state part

local function save(K) K.persist.set('m.threat', st) end

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

function M.init(K)
  local p = K.persist.get('m.threat')
  st = {v = 2, inv = -1, undead = -1, scan = -1}
  if type(p) == 'table' then
    for _, k in ipairs({'inv', 'undead', 'scan'}) do st[k] = int(p[k]) or -1 end
  end
  seen_inv, far_seen, pub = {}, {}, nil
end

local function arm(K, window, tick)
  local until_ = tick + M.ARM
  if until_ > st[window] then st[window] = until_; save(K) end
end

-- fast scan armed: any window open
function M.armed(K)
  local t = K.now().tick
  local u = math.max(st.inv, st.undead, st.scan)
  return (t < u) and 1 or 0, u
end

---------------------------------------------------------------- reach
-- bridge footprints and the z band from the manifest; nil without bridges (then everything counts)
local function fort_geo(K)
  local man = K.manifest()
  local fps, zlo, zhi = {}, nil, nil
  for _, b in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    local f = type(b) == 'table' and b.fp
    if type(f) == 'table' and #f == 6 then
      fps[#fps + 1] = f
      zlo = math.min(zlo or f[3], f[3])
      zhi = math.max(zhi or f[6], f[6])
    end
  end
  if #fps == 0 then return nil end
  local a = type(man.refuge) == 'table' and man.refuge.anchor
  if type(a) == 'table' and type(a[3]) == 'number' then zlo = math.min(zlo, a[3]) end
  local okc, n, sh = K.call('runner', 'cavern_open')
  local shafts = okc and type(n) == 'number' and n > 0 and type(sh) == 'table' and sh or nil
  return {fps = fps, zlo = zlo - M.BAND_BELOW, zhi = zhi + M.BAND_ABOVE, shafts = shafts}
end

-- xy distance (Chebyshev) to the nearest bridge footprint; huge when off the z band; 0 beside an open cavern shaft
local function reach(e, geo)
  if not geo then return 0 end
  for _, s in ipairs(geo.shafts or {}) do
    if type(s) == 'table' and type(s[4]) == 'number' and e.z >= s[4] - M.SHAFT_DZ and e.z <= s[3]
       and math.max(math.abs(e.x - s[1]), math.abs(e.y - s[2])) <= M.SHAFT_R then return 0 end
  end
  if e.z < geo.zlo or e.z > geo.zhi then return math.huge end
  local best = math.huge
  for _, f in ipairs(geo.fps) do
    local dx = e.x < f[1] and f[1] - e.x or (e.x > f[4] and e.x - f[4] or 0)
    local dy = e.y < f[2] and f[2] - e.y or (e.y > f[5] and e.y - f[5] or 0)
    local d = math.max(dx, dy)
    if d < best then best = d end
  end
  return best
end

-- Run 11: tiles from a citizen outside Kern+ within which an animal invader counts (reflex.predator_near; 0 = no limit:
-- the danger rule); nil = the danger rule
local function animal_near(K)
  local r = type(K.cfg.reflex) == 'table' and K.cfg.reflex or {}
  local n = int(r.predator_near)
  if n == nil or n < 0 or n > 400 then n = M.CIT_NEAR end
  return n > 0 and n or nil
end

-- does census.h list entry e count within xy radius r? an = the predator rule's limit for an animal invader (or nil)
local function counts(e, geo, r, an)
  if e.k == 'inv' then return true end
  if e.an == 1 and an then
    return (e.zn or 0) == 2 or (type(e.dc) == 'number' and e.dc >= 0 and e.dc <= an)
  end
  if type(e.dc) == 'number' and e.dc >= 0 and e.dc <= M.CIT_NEAR then return true end
  return reach(e, geo) <= r
end

-- Run 11: the hostiles reflex lists as expired far ({[id] = true}), or nil
local function far_ids(K)
  local ok, f = K.call('reflex', 'far_ids')
  return ok and type(f) == 'table' and next(f) ~= nil and f or nil
end

---------------------------------------------------------------- assess
-- FSM inputs from the census; nil before the first hostile scan
--   hostile: something that justifies ALERT; calm: nothing within the quiet reach (ALERT exit)
--   siege: why a SIEGE is due (great, invaders, invasion, undead) or nil
--   quiet: RECOVERY clock runs (0 invaders map-wide, 0 counted great, 0 inside, 0 dangers near O1)
function M.assess(K)
  local h = K.census.h
  if type(h) ~= 'table' then return nil end
  local now = K.now().tick
  local a = {vis = h.vis or 0, inv = h.inv or 0, great = h.great or 0, undead = h.undead or 0,
             inside = h.inside or 0, near_o1 = h.near_o1 or -1, near_cit = h.near_cit or -1,
             near_bridge = h.near_bridge or {}, tick = h.tick or 0,
             -- intake waves (Gordon 2026-10-16, sense): hostiles in the intake area / past B1, dangerous ones
             zin = h.zin or 0, zpast = h.zpast or 0, dz = h.dz or 0, dz_o1 = h.dz_o1 or -1,
             bd = h.bd or 0}            -- BUG-030: visible building destroyers (siege's deep defense)
  a.fresh = now - a.tick <= M.FRESH
  local geo = fort_geo(K)
  local an, far = animal_near(K), far_ids(K)
  local rel, wide, great_rel, great_wide, undead_rel, near, nfar, far_inv = 0, 0, 0, 0, 0, 0, 0, 0
  for _, e in ipairs(h.list or {}) do
    if far and far[e.id] and e.k ~= 'great' then
      nfar = nfar + 1
      if e.k == 'inv' then far_inv = far_inv + 1 end
    else
      if counts(e, geo, M.REACH, an) then
        rel = rel + 1
        if e.k == 'great' then great_rel = great_rel + 1 end
        if e.k == 'undead' then undead_rel = undead_rel + 1 end
      end
      if counts(e, geo, M.REACH_QUIET, an) then
        wide = wide + 1
        if e.k == 'great' then great_wide = great_wide + 1 end
        -- visible dangers near O1 (without an O1 in the manifest every counted hostile is near)
        if e.d_o1 == nil or e.d_o1 < 0 or e.d_o1 <= M.NEAR_O1 then near = near + 1 end
      end
    end
  end
  a.rel, a.great_rel, a.near_dangers, a.far = rel, great_rel, near, nfar
  a.inv = math.max(0, a.inv - far_inv)     -- Run 11: invaders whose lockdown expired far count again on approach
  local inv_armed = now < st.inv
  if great_rel > 0 then a.siege = 'great'
  elseif a.inv >= M.SIEGE_INV then a.siege = 'invaders'
  elseif a.inv > 0 and inv_armed then a.siege = 'invasion'
  elseif undead_rel > 0 and now < st.undead then a.siege = 'undead' end
  a.hostile = a.inv > 0 or a.inside > 0 or rel > 0
  -- quiet: on visibility only, never on path existence (DESIGN §4, §16)
  a.quiet = a.fresh and a.inv == 0 and great_wide == 0 and a.inside == 0 and near == 0
  a.calm = a.fresh and a.inv == 0 and a.inside == 0 and wide == 0
  return a
end

function M.step(K, budget, ctx)
  local h = K.census.h
  pub = {threat = {vis = type(h) == 'table' and (h.vis or 0) or 0, armed = (M.armed(K))}}
  if type(h) ~= 'table' or (h.great or 0) == 0 then return end
  local geo
  for _, e in ipairs(h.list or {}) do
    if e.k == 'great' and not far_seen[e.id] then
      geo = geo or fort_geo(K)
      if not counts(e, geo, M.REACH_QUIET, nil) then
        far_seen[e.id] = true
        local q = string.format('great danger %d visible out of reach at %d,%d,%d: no siege; seal, watch or sortie?',
                                e.id, e.x, e.y, e.z)
        K.emit('DECISION_NEEDED', 'A', q, {id = 'great_far', q = q, unit = e.id})
      end
    end
  end
end

M.on = {
  INVASION = function(K, ev)
    local now = K.now().tick
    arm(K, 'inv', now)
    local id = int(ev.id) or -1
    if not seen_inv[id] then
      seen_inv[id] = true
      K.emit('INVASION', 'A', 'invasion ' .. string.format('%d', id) .. ' armed the threat scan', {id = id})
    end
  end,
  REPORT = function(K, ev)
    local w = REPORT_WINDOW[ev.type]
    if w then
      arm(K, w, K.now().tick)
      if w ~= 'scan' then arm(K, 'scan', K.now().tick) end
    end
  end,
}

function M.state(K) return pub or {} end

return M
