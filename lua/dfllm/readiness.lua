-- readiness (WP6): levels R0-R3 (DESIGN §5.4) and the ONLY max-pop writer (act.popcap ->
-- `pop-control set max-pop N`, pop-control.lua:52-63). Growth is earned:
--   R0  cap 55
--   R1  "sealed": worst-case audit passes (inbox `audit` from bp.topo.audit), Kern+ and Tiefe+ exist,
--       an outer and an inner bridge exist and every manifest bridge has 2 linked levers
--   R2  R1 + a drill passed <= 100,800 ticks ago (and after the last siege), soldiers >= D-12 share
--       of adults and >= 8, combat value per soldier >= plan.military.cv_min, >= 30 armed traps on
--       every attacker path (audit.min_traps), food >= 60 and drink >= 170 days (plan.supply)
--   R3  R2 + D-01 = B + >= 20 % of soldiers in iron or steel body armor
-- Cap = min(level cap, plan.policy.pop_ceiling, inbox popcap.lower). A demotion freezes max-pop at
-- the current population; outside PEACE max-pop never rises. Audits are requested monthly and
-- after defense stages through snapshot.export (WP7); the result comes back as the `audit` verb
-- (sent by `dfllm follow`, also with --no-auto, or once by `dfllm audit`).
-- R0 -> R1 blockers (state ready.fail, DESIGN §5.4): audit (no result yet), audit_old (> a season), audit_fail
-- (bp.topo.audit ok=false), bypass, refuge_sep, civ_sep, caverns (its flags; Run 11: also an explore shaft open to a
-- cavern until its plug wall stands, runner.cavern_open), no_kern, no_refuge (burrows), refuge_dry (Run 11, siege 8:
-- the refuge holds no drink by seal's audit, seal.refuge_drink: drink < citizens and no well, or its wells are dry by
-- water's state refuge_ok 0; SIEGE_UNREADY says what to build: FR-69 the refuge drink store, or that it waits for
-- barrels), burrow_lost (BUG-096, Run 14 note 70: seal's burrow guard found Kern+ or the refuge shrunk or gone and the
-- lost tiles held a well or the refuge, seal.burrow_guard; the kernel paints them again), hospital_out (BUG-036, Run 11
-- siege 9: a hospital
-- zone with tiles outside Kern+ and the refuge by water's state hosp_out; its lying patients cannot walk to the refuge),
-- no_outer, no_inner (no manifest bridge of that role; BUG-130: a wall + door is no gate, it clears open_perimeter
-- only, and a fortcore parked on a breach is re-sited by plan propose, never counted), bridge:<B> (gate does not know it), levers:<B> (< 2 linked),
-- lost:<B> (BUG-030 rebuild policy, BUG-048: a bridge the perimeter keeper replaces by a wall + door after
-- perimeter.stop_after losses to building destroyers, seal.lost_gates; it stands for bridge:<B> and levers:<B> until the
-- closure stands: the kernel queues it, no question), refuge_trust (BUG-049: seal.refuge_trust says the refuge is
-- exposed, has no closer on its stair head or its separation answer is stale), mood_ws (BUG-117, Run 14 note 92: a moodable
-- workshop type missing for offices.mood_ws_days days in a fort of offices.mood_ws_pop citizens; M.mood_ws_blocker), open_perimeter
-- (FR-70, below).
-- open_perimeter (FR-70, Run 11 y483-y497 and Run 13 y507-y525: a door open for 14 years, O1/B1/B2 and their levers
-- lost for 18, 60 citizens lost in two sieges and a fort fallen over an open O1): a way in without door or bridge, a
-- lost bridge (gate found it destroyed and it is no wall + door yet) or a lost lever (a bridge whose 2 linked levers
-- were seen once) in PEACE is a stop signal, not a state to live with. R0 at once; from perimeter.escalate_days days on
-- the SIEGE_UNREADY wake repeats every perimeter.escalate_every days (and 5 real minutes) instead of monthly, with the
-- days counted; a fort of perimeter.hold_pop citizens or more holds max-pop where it stands (the cap never rises while
-- the perimeter is open). state ready.pd = the days, ready.pw = what is open. Outside PEACE the signal keeps its last
-- answer (a lockdown's open gates are no news). A bridge seal replaced by a wall + door is no lost bridge.
-- FR-65 siege readiness gate: while R0 fails in PEACE, SIEGE_UNREADY (A) names the blockers, the ways in without a
-- door or bridge (seal.entrance_doors) and the trap count of the last audit; first at once (2 days after a load),
-- then again after a game month and 30 real minutes, or 10 when it got worse (util/cadence).
-- Run 10 (the bypass finding stood for months, the 41 traps stayed unused): the last audit's first attacker-route
-- finding (`bypass: wall x,y,z floor -> X`, `refuge: on the attack path, wall ...`) stands in SIEGE_UNREADY with its
-- fix (`seal at=audit` builds the named wall) and in the state (ready.route) for status and `dfllm plan check`.
local geom = require('dfllm.util.geom')
local CAD = require('dfllm.util.cadence')

local M = {name = 'readiness', every = {ticks = 1200}, verbs = {}, on = {}}

M.CAPS = {[0] = 100, [1] = 100, [2] = 100, [3] = 250}
M.SIEGE_TRIGGER = 80     -- difficulty "enemy population trigger" [S10: read it]; R2 ceiling = trigger - 5
M.DRILL_VALID = 100800   -- a passed drill counts for one season
M.AUDIT_VALID = 100800   -- an audit counts for one season
M.AUDIT_EVERY = 33600    -- re-audit monthly
M.AUDIT_GAP = 1200       -- at most one audit request per day
M.LEVERS_EVERY = 1200    -- FR-70: lost levers are looked for daily (a few findAtTile reads); it was a month
-- FR-70 (config/reflex.json perimeter): days of an open perimeter before the wake repeats faster and max-pop freezes,
-- days between those wakes, the citizens from which the freeze applies (0 = never), real seconds between the wakes
M.PERIM = {escalate_days = 2, escalate_every = 5, hold_pop = 30}
M.PERIM_LIM = {escalate_days = {0, 30}, escalate_every = {1, 30}, hold_pop = {0, 250}}
M.PERIM_WALL_S = 300
M.MIN_LEVERS, M.TRAPS, M.METAL, M.R2_SOLDIERS = 2, 30, 20, 8
M.STOCK_HYST = 90        -- % of a stock minimum that keeps R2 once reached (no flapping)
-- FR-65 SIEGE_UNREADY cadence (util/cadence): a game month, and at least UNREADY_WALL_S real seconds for an unchanged
-- R0 (at timestream speed a month is 75 s) or UNREADY_NEWS_S when a new blocker or a new open way in appeared
M.UNREADY_EVERY, M.UNREADY_WALL_S, M.UNREADY_NEWS_S = 33600, 1800, 600
M.UNREADY_SETTLE = 2400  -- not in the first 2 days after a load (seal's first entrance check, the lever check)
M.ENTS = 6               -- ways in named by SIEGE_UNREADY (the state keeps 3)
local QUIET_MODES = {PEACE = true, ALERT = true, RECOVERY = true}   -- audit snapshots allowed

local st      -- persisted m.readiness
local rt      -- runtime: lever check, published values
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.readiness', st); dirty = false end end
local function try(f, ...) local ok, r = pcall(f, ...); if ok then return r end end
local function cut(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end

local function sorted_keys(t)
  local r = {}
  for k in pairs(type(t) == 'table' and t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

---------------------------------------------------------------- inputs
local function burrow_names(man)
  local kern, refuge
  for _, name in ipairs(sorted_keys(man.burrows)) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  return kern or 'Kern+', refuge or 'Tiefe+'
end

local function plan_loaded(K)
  local p = K.persist.get('plan')
  return type(p) == 'table' and int(p.loaded) or -1
end

-- the newest passed drill and the newest drill of any result (persist `drill`, written by drill)
local function drills(K)
  local d = K.persist.get('drill')
  local pass, last
  for _, e in ipairs(type(d) == 'table' and type(d.last) == 'table' and d.last or {}) do
    if type(e) == 'table' and int(e.tick) then
      if not last or e.tick >= last.tick then last = e end
      if e.pass == 1 and (not pass or e.tick >= pass.tick) then pass = e end
    end
  end
  return pass, last
end

-- army share (%) from D-12 '<low>/<high>' (low below pop 60) and plan.military.pct
local function share(K, cit)
  local lo, hi = tostring((K.cfg.decisions or {})['D-12'] or '15/20'):match('^(%d+)/(%d+)$')
  local p = (cit or 0) >= 60 and (tonumber(hi) or 20) or (tonumber(lo) or 15)
  local mil = type(K.plan) == 'table' and K.plan.military
  local pp = type(mil) == 'table' and int(mil.pct)
  if pp and pp > p then p = pp end
  return math.tointeger(p) or 15
end

local function plan_num(K, sect, key, default)
  local s = type(K.plan) == 'table' and K.plan[sect]
  return type(s) == 'table' and int(s[key]) or default
end

-- a manifest lever is a lever building linked to the bridge on fp (gate.lua:77-87, lever.lua:24-27)
local function lever_ok(p, fp)
  return try(function()
    local b = dfhack.buildings.findAtTile(p[1], p[2], p[3])          -- Lua API.txt:2484
    if not b or b.trap_type ~= df.trap_type.Lever or #b.linked_mechanisms == 0 then return false end
    local c = geom.bbox_center(fp)
    for _, m in ipairs(b.linked_mechanisms) do
      local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
      local t = ref and ref:getBuilding()
      if not t then return true end                                   -- unreadable target: trust the link
      if t.z == c.z and c.x >= t.x1 and c.x <= t.x2 and c.y >= t.y1 and c.y <= t.y2 then return true end
    end
    return false
  end) == true
end

-- bridges and levers: outer + inner exist, every bridge known to gate, >= 2 linked levers each
local function check_levers(K, man)
  local fails, roles, good = {}, {}, {}
  -- BUG-048: a bridge seal replaced by a wall and a door is no gate: no bridge:/levers: blocker, and its role is
  -- missing (no_outer / no_inner say so: the doctrine wants a gate there)
  local okr, rep = K.call('seal', 'replaced')
  rep = okr and type(rep) == 'table' and rep or {}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 and not rep[name] then
      roles[b.role or '?'] = true
      local ok, s = K.call('gate', 'state', name)
      if not ok or s == 'unknown' then fails[#fails + 1] = 'bridge:' .. name end
      local n = 0
      for _, p in ipairs(type(b.levers) == 'table' and b.levers or {}) do
        if type(p) == 'table' and lever_ok(p, b.fp) then n = n + 1 end
      end
      if n < M.MIN_LEVERS then fails[#fails + 1] = 'levers:' .. name
      elseif ok and s ~= 'unknown' then good[#good + 1] = name end      -- FR-70: once seen whole, losing one is news
    end
  end
  if not roles.outer then table.insert(fails, 1, 'no_outer') end
  if not roles.inner then table.insert(fails, 1, 'no_inner') end
  return {tick = K.now().tick, fails = fails, good = good}
end

---------------------------------------------------------------- audit requests
-- BUG-043 (Run 11 y479: 'audit snapshot not exported: bbox has 308132 tiles > 250000', then 370,414): readiness built
-- its own box (the manifest geometry + PAD, every running project's box + PAD: an explore 12 levels below the core
-- added whole planes of the fort). The box is snapshot's default for an audit now (snapshot.lua's pieces: the manifest
-- geometry and runner.boxes, an explore shaft as a column part, the margin shrunk stepwise over the cap), the same
-- one `dfllm audit` gets; readiness only asks once the manifest has geometry.
local function has_geometry(man)
  for _, k in ipairs({'bridges', 'zones', 'killboxes', 'stations', 'edge', 'stairs'}) do
    if type(man[k]) == 'table' and next(man[k]) ~= nil then return true end
  end
  return type(man.refuge) == 'table' or type(man.pit) == 'table' or type(man.depot) == 'table'
end

local function request_audit(K, force)
  local now = K.now().tick
  if not QUIET_MODES[K.mode()] then st.audit_due, dirty = 1, true; return end
  if st.audit_req and now - st.audit_req < (force and M.AUDIT_GAP or M.AUDIT_EVERY) then
    if force then st.audit_due, dirty = 1, true end
    return
  end
  -- BUG-033 (Run 11: a monthly request every ~75 s real time while each export waited behind the last): the monthly
  -- audit waits while the previous audit snapshot is still queued or being exported
  if not force and st.audit_snap then
    local okp, pend = K.call('snapshot', 'pending', st.audit_snap)
    if okp and pend == true then
      K.log('info', 'readiness: monthly audit waits for snapshot %s (still queued or exporting)', st.audit_snap)
      return
    end
  end
  if not has_geometry(K.manifest()) then return end          -- nothing built yet
  -- live L2: a bedrooms dig still in progress ran past the box edge; the audit took the cut-off corridor for a way in
  -- (bypass) and readiness fell R1 -> R0: running projects are in the box (snapshot.lua's pieces: runner.boxes)
  st.audit_req, st.audit_due, dirty = now, 0, true
  local ok, ok2, id = K.call('snapshot', 'export', {purpose = 'audit', by = 'readiness'})
  if ok and ok2 then
    st.audit_snap, st.audit_why = tostring(id), nil
  else
    -- BUG-043: the refusal stays in the state (ready.audit.why) until an audit snapshot is exported again
    st.audit_why = cut(ok and id or ok2, 80)
    K.log('warn', 'readiness: audit snapshot not exported: %s', tostring(ok and id or ok2))
  end
end

-- FR-65: seal's last entrance check (CONTRACTS §7 seal.entrance_doors): independent routes from the map edge to
-- the citizens, those with neither a door nor a bridge, and those as 'x,y,z kind'; -1, -1 before the first check
local function entrances(K)
  local ok, x = K.call('seal', 'entrance_doors')
  if not ok or type(x) ~= 'table' then return -1, -1, {} end
  local open = type(x.open) == 'table' and x.open or {}
  local ents = {}
  for _, o in ipairs(open) do
    local p = type(o) == 'table' and o.pos
    if type(p) == 'table' and int(p[1]) and int(p[2]) and int(p[3]) and #ents < M.ENTS then
      ents[#ents + 1] = cut(string.format('%d,%d,%d %s', p[1], p[2], p[3], tostring(o.kind or '?')), 24)
    end
  end
  return math.max(0, int(x.routes) or 0), #open, ents
end

-- the last audit's first attacker-route finding (bp.topo.audit: a bypass of the trap hall, a refuge on the attack
-- path), nil without one
M.ROUTES = {'^bypass:', '^refuge: on the attack path'}
local function route_of(a)
  for _, f in ipairs(type(a) == 'table' and type(a.fails) == 'table' and a.fails or {}) do
    for _, pat in ipairs(M.ROUTES) do
      if type(f) == 'string' and f:find(pat) then return f end
    end
  end
end

---------------------------------------------------------------- BUG-040: where the refuge lies
-- Run 11 (y453: 'Tiefe+ has no drink' for months, and nobody knew where Tiefe+ lies or how far the one wet well was):
-- seal.refuge_drink's bbox and nearest tile to an accepted source (seal's burrow audit, no scan of its own) as
-- 'Tiefe+ 126-128,56-77 z129-136, nearest accepted water: well 19098 at 137,77,143 in Kern+, 9 tiles'; second value the
-- source's label, third whether the refuge has no accepted water of its own (water's state refuge_ok 0: a hospital
-- then belongs into Kern+ next to that water)
local function refuge_where(K, rd)
  if type(rd) ~= 'table' or type(rd.box) ~= 'table' or not int(rd.box[1]) then return nil end
  local b = rd.box
  local s = string.format('%s %d-%d,%d-%d z%d-%d', tostring(rd.name), b[1], b[4], b[2], b[5], b[3], b[6])
  local wv = K.view().water
  local dry = type(wv) == 'table' and wv.refuge_ok == 0
  local n = rd.near
  if type(n) ~= 'table' or type(n.src) ~= 'table' or not int(n.d) then
    return s .. ', no accepted water in the fort', nil, true
  end
  local okl, lbl = K.call('water', 'label', n.src[1], n.src[2], n.src[3])
  lbl = okl and type(lbl) == 'string' and lbl or string.format('accepted water at %d,%d,%d', n.src[1], n.src[2],
                                                                n.src[3])
  return s .. string.format(', nearest accepted water: %s, %d tiles', lbl, n.d), lbl, dry
end

---------------------------------------------------------------- BUG-055: vacant offices
-- config/baseline.json "offices": blocker_days (7, 0 = never a blocker); the offices that block are the manager (no order
-- is validated without one) and the hospital's chief medical dwarf; squads that cannot get a leader block too
M.OFFICES = {days = 7, codes = {MANAGER = true, CHIEF_MEDICAL_DWARF = true}}
function M.office_blocker(K, now)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.offices
  local days = type(c) == 'table' and int(c.blocker_days) or M.OFFICES.days
  if days == nil or days < 0 or days > 400 then days = M.OFFICES.days end
  if days == 0 then return nil end
  local okc, offs = K.call('economy', 'offices')
  if okc and type(offs) == 'table' then
    for _, o in ipairs(offs) do
      if M.OFFICES.codes[o.code] and (int(o.days) or 0) >= days then
        local fix = o.cand and string.format('dfllm cmd appoint {"code":"%s","unit":%d}', o.code, o.cand)
                    or (o.why or 'no candidate')
        return cut(string.format('%s vacant %d days (ACTIVE%s): %s', o.code, o.days, o.why and (', ' .. o.why) or '', fix),
                   200)
      end
    end
  end
  local okm, ls = K.call('military', 'leader_state')
  if okm and type(ls) == 'table' and ls.why and int(ls.since) and now - ls.since >= days * 1200 then
    return cut(ls.why .. '; fix: dfllm cmd squad.create {name, leader} or appoint {code, unit}', 200)
  end
  return nil
end

---------------------------------------------------------------- BUG-117: moodable workshops missing
-- config/baseline.json "offices": mood_ws_days (7, 0 = never a blocker) and mood_ws_pop (20, citizens from which it
-- counts; a strange mood needs a fort of that size, and a fort of 7 builds its shops by its plan). Run 14 note 92: 151
-- of 453 citizen deaths were failed strange moods, the Loom was missing for a while. A moodable workshop type
-- (economy.mood_shops: from mood_from_phase on) missing on the map for mood_ws_days game days is the R0 blocker `mood_ws`
-- with the ready bp.place command for the first three types no `workshops` project builds yet (one that does is named).
-- The days count from the first look that found it missing in a fort of that size (state mws: type -> tick)
M.MWS = {days = 7, pop = 20}
function M.mood_ws_blocker(K, now)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.offices
  c = type(c) == 'table' and c or {}
  local days, pop = int(c.mood_ws_days), int(c.mood_ws_pop)
  if days == nil or days < 0 or days > 400 then days = M.MWS.days end
  if pop == nil or pop < 0 or pop > 250 then pop = M.MWS.pop end
  local cu = K.census and K.census.u
  local cit = type(cu) == 'table' and int(cu.cit) or 0
  local okm, ms = false, nil
  if days > 0 and cit >= math.max(pop, 1) then okm, ms = K.call('economy', 'mood_shops') end
  if not (okm and type(ms) == 'table' and type(ms.missing) == 'table') then
    if st.mws then st.mws, dirty = nil, true end              -- nothing known or nothing to ask: the clocks start again
    return nil
  end
  local miss = {}
  for _, t in ipairs(ms.missing) do miss[t] = true end
  st.mws = st.mws or {}
  for t in pairs(st.mws) do if not miss[t] then st.mws[t], dirty = nil, true end end
  local list, oldest = {}, 0
  for _, t in ipairs(ms.missing) do
    if type(t) == 'string' then
      if not st.mws[t] then st.mws[t], dirty = now, true end
      local age = math.max(0, (now - st.mws[t]) // 1200)
      if age >= days then list[#list + 1] = t; oldest = math.max(oldest, age) end
    end
  end
  if #list == 0 then return nil end
  local ask, queued = {}, {}
  local qd = type(ms.queued) == 'table' and ms.queued or {}
  for _, t in ipairs(list) do
    if type(qd[t]) == 'table' then queued[#queued + 1] = string.format('%s %s %s%%', t, cut(qd[t].id, 12), tostring(int(qd[t].pct) or 0))
    else ask[#ask + 1] = t end
  end
  local head = string.format('mood shops missing %d days: %s%s', oldest, table.concat(list, ',', 1, math.min(#list, 3)),
                             #list > 3 and string.format(' +%d', #list - 3) or '')
  local parts = {head}
  if #ask > 0 then
    local only = table.concat(ask, ',', 1, math.min(#ask, 3))
    parts[#parts + 1] = string.format('dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"%s"}}', only)
  end
  if #queued > 0 then parts[#parts + 1] = 'queued ' .. table.concat(queued, ', ', 1, math.min(#queued, 2)) end
  return cut(table.concat(parts, '; '), 200)
end

---------------------------------------------------------------- levels
local function audit_fails(K, now)
  local a = st.audit
  if type(a) ~= 'table' then return {'audit'} end
  local f = {}
  if now - a.tick > M.AUDIT_VALID then f[#f + 1] = 'audit_old' end
  if a.ok ~= 1 then f[#f + 1] = 'audit_fail' end
  if a.bypass ~= 0 then f[#f + 1] = 'bypass' end
  if a.refuge_sep ~= 1 then f[#f + 1] = 'refuge_sep' end
  if a.civ_sep ~= 1 then f[#f + 1] = 'civ_sep' end
  if a.caverns ~= 1 then f[#f + 1] = 'caverns' end
  return f
end

-- FR-70 knobs: config/reflex.json perimeter.escalate_days / escalate_every / hold_pop (bad value: the default)
local function pcfg(K, key)
  local r = type(K.cfg) == 'table' and type(K.cfg.reflex) == 'table' and K.cfg.reflex.perimeter or nil
  local v = type(r) == 'table' and int(r[key]) or nil
  local lim = M.PERIM_LIM[key]
  if v and v >= lim[1] and v <= lim[2] then return v end
  return M.PERIM[key]
end

-- FR-70: what is open in the perimeter now, {ways in, lost bridges, lost levers} as a short text, or nil. Called with
-- the entrance check (rt.open) and the lever check (rt.lev) of this evaluation. A bridge gate found destroyed counts
-- until it stands again or seal made it a wall + door; levers only for a bridge whose levers were seen whole once.
local function open_perimeter(K, man)
  local why, lostb, lostl = {}, {}, {}
  local okr, rep = K.call('seal', 'replaced')
  rep = okr and type(rep) == 'table' and rep or {}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 and not rep[name] then
      local ok, _, _, gone = K.call('gate', 'state', name)
      if ok and gone then lostb[#lostb + 1] = name end
    end
  end
  local isl = {}
  for _, b in ipairs(lostb) do isl[b] = true end
  for _, f in ipairs(rt.lev and rt.lev.fails or {}) do
    local b = f:match('^levers:(.+)$')
    if b and st.lvok and st.lvok[b] and not isl[b] and not rep[b] then lostl[#lostl + 1] = b end
  end
  local open = rt.open or -1
  if open > 0 then why[#why + 1] = string.format('%d way%s in', open, open == 1 and '' or 's') end
  if #lostb > 0 then why[#why + 1] = 'bridges lost: ' .. table.concat(lostb, ',') end
  if #lostl > 0 then why[#why + 1] = 'levers lost: ' .. table.concat(lostl, ',') end
  return #why > 0 and cut(table.concat(why, '; '), 60) or nil
end

local function evaluate(K, why)
  local now = K.now().tick
  local man = K.manifest()
  local cu = K.census.u
  local okm, kpi = K.call('military', 'kpi')
  kpi = okm and type(kpi) == 'table' and kpi or nil
  -- R1
  local f1 = audit_fails(K, now)
  rt.audit_ok = #f1 == 0 and 1 or 0
  -- Run 11: an explore shaft open to a cavern (runner.cavern_open) keeps R0 until its plug wall stands, also when the
  -- shaft has left the audit box (project cancelled) or the audit read it as closed
  local okc, ncav = K.call('runner', 'cavern_open')
  if okc and type(ncav) == 'number' and ncav > 0 then
    local has = false
    for _, f in ipairs(f1) do if f == 'caverns' then has = true end end
    if not has then f1[#f1 + 1] = 'caverns' end
  end
  rt.routes, rt.open, rt.ents = entrances(K)                       -- FR-65 (FR-70: before the blockers)
  local kern, refuge = burrow_names(man)
  if not dfhack.burrows.findByName(kern) then f1[#f1 + 1] = 'no_kern' end
  rt.rdry = nil
  if not dfhack.burrows.findByName(refuge) then f1[#f1 + 1] = 'no_refuge'
  else
    -- Run 11 (siege 8: Tiefe+ had no drink; a dry refuge holds the citizens only in a breach, for a week)
    local okd, rd = K.call('seal', 'refuge_drink')
    if okd and type(rd) == 'table' and rd.exists == true then
      local wv = K.view().water
      local wells_dry = (int(rd.wells) or 0) > 0 and type(wv) == 'table' and wv.refuge_ok == 0
      if (int(rd.drink) or 0) < (int(rd.need) or 0) and ((int(rd.wells) or 0) == 0 or wells_dry) then
        f1[#f1 + 1] = 'refuge_dry'
        -- BUG-035 (Run 11: 13 wells, 1 wet, none in Tiefe+): whether the refuge has no well or only dry ones
        local nw = int(rd.wells) or 0
        local where = refuge_where(K, rd)                 -- BUG-040: where it lies, its nearest accepted water
        -- FR-69 (Run 11 y477: 1199 drinks in one Kern+ pile, none in Tiefe+): the fix is the refuge drink store
        -- (bp refuge_drink, plan propose drafts it); one that stands (seal sees its pile there) waits for barrels
        local sto = type(rd.store) == 'table' and (int(rd.store.tiles) or 0) > 0 and rd.store or nil
        rt.rdry = cut(string.format('%s has no drink (drink %d<%d, %s%s): %s',
                                    tostring(rd.name), int(rd.drink) or 0, int(rd.need) or 0,
                                    nw == 0 and ('no well in ' .. tostring(rd.name))
                                    or (nw == 1 and 'its 1 well is dry' or string.format('its %d wells are dry', nw)),
                                    where and ('; ' .. where) or '',
                                    sto and string.format('its drink store (%d tiles) waits for barrels', sto.tiles)
                                    or 'plan its drink store (bp sites refuge_drink)'), 200)
      end
    end
  end
  -- BUG-036 (Run 11 siege 9: two cave dragons killed 7 patients in their hospital beds): a hospital outside Kern+ and
  -- the refuge (water's state hosp_out; no water state: no blocker, fail-open). Its patients cannot walk to the refuge
  rt.hout = nil
  local wv = K.view().water
  if type(wv) == 'table' and (int(wv.hosp_out) or 0) > 0 then
    f1[#f1 + 1] = 'hospital_out'
    local okh, ho = K.call('water', 'hospital_out')
    local z = okh and type(ho) == 'table' and type(ho.zones) == 'table' and ho.zones[1] or nil
    -- BUG-040 (Run 11 y453: Tiefe+ had no accepted water at all): then the hospital goes into Kern+ next to the water
    local okd, rd = K.call('seal', 'refuge_drink')
    local _, lbl, dry = refuge_where(K, okd and rd or nil)
    local dest = string.format('move it into %s next to accepted water', refuge)
    if dry and lbl then                                -- 'in Kern+' stands in the label when the water lies there
      dest = string.format('no accepted water in %s: move it %snext to %s', refuge,
                           lbl:find(' in ' .. kern, 1, true) and '' or ('into ' .. kern .. ' '), lbl)
    elseif dry then
      dest = string.format('no accepted water in the fort: water first, then the hospital in %s next to it', kern)
    end
    rt.hout = cut(string.format('the hospital lies outside %s/%s (%d of %d zones%s): its patients cannot walk to the '
                                .. 'refuge; %s', kern, refuge, int(wv.hosp_out) or 0,
                                okh and type(ho) == 'table' and int(ho.total) or (int(wv.hosp) or 0),
                                z and string.format('; zone %d at %d,%d,%d', int(z.id) or -1, int(z.x) or -1,
                                                    int(z.y) or -1, int(z.z) or -1) or '', dest), 200)
  end
  -- BUG-096/FR-80 (Run 14 note 70: Kern+ shrank to about one tile and Tiefe+ vanished): seal's burrow guard found a burrow
  -- that lost tiles holding a well or the refuge. The hospital has hospital_out above (not counted twice); an episode over
  -- other tiles is in the status only (alert.bg), no blocker
  rt.blost = nil
  local okb, bgl = K.call('seal', 'burrow_guard')
  for _, e in ipairs(okb and type(bgl) == 'table' and bgl or {}) do
    local held = {}
    for _, c in ipairs(type(e.crit) == 'table' and e.crit or {}) do
      if c == 'well' then held[#held + 1] = 'a well' elseif c == 'refuge' then held[#held + 1] = 'the refuge' end
    end
    if #held > 0 then
      f1[#f1 + 1] = 'burrow_lost'
      rt.blost = cut(string.format('%s %s (%d -> %d tiles) and held %s: %s', tostring(e.name),
                                   e.gone and 'is gone' or 'lost its tiles', int(e.was) or 0, int(e.now) or 0,
                                   table.concat(held, ' and '), tostring(e.st or 'see status')), 200)
      break
    end
  end
  -- BUG-055 (Run 14 y577: the CHIEF_MEDICAL_DWARF office stood vacant for good, nobody noticed): an office the kernel did
  -- not fill within offices.blocker_days, or squads it cannot give a leader
  rt.office = nil
  local otext = M.office_blocker(K, now)
  -- a young fort cannot always fill an office and must not stop growing for it (the same small-fort guard as FR-70's
  -- perimeter hold, perimeter.hold_pop citizens)
  -- (audit I4: hold_pop 0 means "the perimeter never holds max-pop"; it must not switch this guard off)
  local hp0, cu0 = pcfg(K, 'hold_pop'), K.census and K.census.u
  if hp0 == 0 then hp0 = M.PERIM.hold_pop end
  if otext and hp0 > 0 and type(cu0) == 'table' and (int(cu0.cit) or 0) < hp0 then otext = nil end
  if otext then
    f1[#f1 + 1] = 'office'
    rt.office = otext
  end
  -- BUG-117 (Run 14 note 92): a moodable workshop type missing for mood_ws_days days in a fort that can have a mood
  rt.mws = nil
  local mtext = M.mood_ws_blocker(K, now)
  if mtext then
    f1[#f1 + 1] = 'mood_ws'
    rt.mws = mtext
  end
  if not rt.lev or now - rt.lev.tick >= M.LEVERS_EVERY then rt.lev = check_levers(K, man) end
  local okl, lost = K.call('seal', 'lost_gates')             -- BUG-030 rebuild policy: held bridges
  lost = okl and type(lost) == 'table' and lost or {}
  for _, name in ipairs(sorted_keys(lost)) do f1[#f1 + 1] = 'lost:' .. name end
  for _, f in ipairs(rt.lev.fails) do
    local b = f:match('^bridge:(.+)$') or f:match('^levers:(.+)$')
    if not (b and lost[b]) then f1[#f1 + 1] = f end
  end
  -- FR-70: the open perimeter. A bridge seen whole with 2 linked levers is remembered (a lost lever is news)
  for _, name in ipairs(rt.lev.good or {}) do
    st.lvok = st.lvok or {}
    if not st.lvok[name] then st.lvok[name], dirty = 1, true end
  end
  -- BUG-049 (Run 13 y525: the refuge was reachable and occupied): the kernel's own reading of the refuge. Exposed, no
  -- hatch on its stair head, or a separation answer gone stale keep R0 (hostiles inside are a fight, the audit has its
  -- own blockers)
  local okt, tr = K.call('seal', 'refuge_trust')
  rt.rtrust = nil
  if okt and type(tr) == 'table' and tr.ok == false then
    local why = tr.why and tr.why[1] or '?'
    if tr.sep == 0 or (tr.hatch and tr.hatch.state == 'missing') or why:find('^separation not checked') then
      f1[#f1 + 1] = 'refuge_trust'
      rt.rtrust = cut(why, 80)
    end
  end
  local peace = K.mode() == 'PEACE'
  if peace then
    rt.pw = open_perimeter(K, man)
    if rt.pw and not st.pt then st.pt, dirty = now, true
    elseif not rt.pw and st.pt then st.pt, st.phold, dirty = nil, nil, true end
  end
  rt.pd = st.pt and math.max(0, (now - st.pt) // 1200) or nil     -- game days (TICKS.DAY)
  if st.pt then
    if not rt.pw then rt.pw = st.pw end
    table.insert(f1, 1, 'open_perimeter')
  end
  if st.pw ~= rt.pw and st.pt then st.pw, dirty = rt.pw, true end
  -- the freeze: from escalate_days days on, a fort of hold_pop citizens or more keeps max-pop where it stands
  local hp, cit0 = pcfg(K, 'hold_pop'), type(cu) == 'table' and cu.cit or nil
  if st.pt and hp > 0 and rt.pd >= pcfg(K, 'escalate_days') and cit0 and cit0 >= hp then
    if not st.phold then st.phold, dirty = cit0, true end
  elseif st.phold and not (st.pt and hp > 0 and cit0 and cit0 >= hp) then st.phold, dirty = nil, true end
  rt.phold = st.phold
  -- R2
  local f2 = {}
  local pass, last = drills(K)
  rt.pass_tick = pass and pass.tick or nil
  if not pass then f2[#f2 + 1] = 'drill'
  elseif now - pass.tick > M.DRILL_VALID then f2[#f2 + 1] = 'drill_old'
  elseif st.siege and pass.tick < st.siege then f2[#f2 + 1] = 'redrill' end
  local adults, cit = type(cu) == 'table' and cu.adults or 0, type(cu) == 'table' and cu.cit or 0
  local soldiers, cv = kpi and kpi.soldiers or 0, kpi and kpi.cv or 0
  local sh = share(K, cit)
  if not kpi then f2[#f2 + 1] = 'military?' end
  if soldiers * 100 < adults * sh then f2[#f2 + 1] = 'army<' .. sh .. '%' end
  if soldiers < M.R2_SOLDIERS then f2[#f2 + 1] = 'soldiers<' .. M.R2_SOLDIERS end
  local cv_min = plan_num(K, 'military', 'cv_min', 12)
  if cv < cv_min then f2[#f2 + 1] = 'cv<' .. cv_min end
  local traps = type(st.audit) == 'table' and st.audit.min_traps or 0
  if traps < M.TRAPS then f2[#f2 + 1] = 'traps<' .. M.TRAPS end
  local stock = K.view().stock
  local hyst = (st.lvl or 0) >= 2 and M.STOCK_HYST or 100
  for _, s in ipairs({{'food_d', 'food', 60}, {'drink_d', 'drink', 170}}) do
    local need = plan_num(K, 'supply', s[1], s[3])
    local have = type(stock) == 'table' and int(stock[s[1]])
    if not have then f2[#f2 + 1] = s[2] .. '?'
    elseif have * 100 < need * hyst then f2[#f2 + 1] = s[2] .. '<' .. need end
  end
  -- R3
  local f3 = {}
  if tostring((K.cfg.decisions or {})['D-01'] or 'A') ~= 'B' then f3[#f3 + 1] = 'option_a' end
  if (kpi and kpi.metal_pct or 0) < M.METAL then f3[#f3 + 1] = 'metal<' .. M.METAL .. '%' end
  local lvl, fail = 0, f1
  if #f1 == 0 then lvl, fail = 1, f2 end
  if lvl == 1 and #f2 == 0 then lvl, fail = 2, f3 end
  if lvl == 2 and #f3 == 0 then lvl, fail = 3, {} end
  local out = {}
  for i = 1, math.min(#fail, 8) do out[i] = cut(fail[i], 24) end
  rt.fail = out
  rt.cv = cv
  rt.worn = last and int(last.worn) or (kpi and kpi.worn) or 0   -- worn measured by the last drill
  local okd, hold = K.call('drill', 'hold')
  rt.dhold = okd and type(hold) == 'string' and cut(hold, 24) or nil
  local okf, nref = K.call('drill', 'refused')                -- BUG-110: drills refused for want of a bridge
  rt.dref = okf and int(nref) and int(nref) > 0 and int(nref) or nil
  local route = route_of(st.audit)
  rt.route = route and cut(route, 60) or nil
  if lvl ~= st.lvl then
    local from = st.lvl or 0
    st.lvl, dirty = lvl, true
    K.emit('READY_CHANGE', 'B', string.format('readiness R%d -> R%d (%s)', from, lvl, why or 'check'),
           {from = from, to = lvl, fail = out})
  end
  return lvl
end

---------------------------------------------------------------- pop cap
local function inbox_cap(K)
  local ib = st.inbox
  if type(ib) == 'table' and int(ib.cap) and ib.plan == plan_loaded(K) then return ib.cap end
  if ib then st.inbox, dirty = nil, true end                 -- a new plan supersedes an inbox lowering
  return nil
end

-- readiness ceiling for a level and the binding limit
function M.ceiling(K, lvl)
  local c, why = M.CAPS[lvl] or M.CAPS[0], 'R' .. lvl
  if lvl == 2 then c = math.min(c, M.SIEGE_TRIGGER - 5) end
  local pc = plan_num(K, 'policy', 'pop_ceiling', nil)
  if pc and pc < c then c, why = pc, 'plan' end
  local ib = inbox_cap(K)
  if ib and ib < c then c, why = ib, 'inbox' end
  if rt and rt.phold and rt.phold < c then c, why = rt.phold, 'open_perimeter' end     -- FR-70
  return c, why
end

local function apply_cap(K)
  local gate, why = M.ceiling(K, st.lvl or 0)
  rt.gate_cap = gate
  local cu = K.census.u
  local cit = type(cu) == 'table' and cu.cit or nil
  local c, last = gate, st.cap
  if last and c < last then
    if not cit then return end                                -- freeze needs the population
    local f = math.max(c, math.min(last, cit))                -- demotion: frozen at the current pop
    if f > c then c, why = f, 'freeze' end
  end
  if last and c > last and K.mode() ~= 'PEACE' then c, why = last, 'frozen' end
  c = math.max(1, c)                                          -- pop-control needs a positive number
  if c == last and rt.applied then return end
  if not K.act.popcap(c) then return end
  rt.applied = true
  if c ~= last then
    st.cap, dirty = c, true
    K.emit('POPCAP', 'B', string.format('max-pop %d (%s)', c, why), {cap = c, why = why})
  end
end

---------------------------------------------------------------- FR-65 siege readiness gate
-- the fix a route finding names: a wall on the tile it gives (the seal template builds it: at=audit)
local function route_fix(route)
  if not route then return nil end
  if route:find('wall %-?%d+,%-?%d+,%-?%d+ ') then return route .. ' (fix: seal at=audit)' end
  return route .. ' (no wall tile: inspect entrances)'
end

local function unready_msg(fails, routes, open, ents, traps, route, rdry, hout, perim, office, blost, mws)
  local ent
  if routes < 0 then ent = 'entrances not checked yet'
  elseif open == 0 then ent = string.format('%d way%s in, all with a door or bridge', routes, routes == 1 and '' or 's')
  else
    local shown = {}
    for i = 1, math.min(#ents, 3) do shown[i] = ents[i] end
    ent = string.format('%d of %d ways in without door or bridge: %s%s', open, routes, table.concat(shown, ', '),
                        open > #shown and ', ...' or '')
  end
  local head = string.format('siege unready (R0: %s); ', #fails > 0 and table.concat(fails, ', ') or '?')
  if perim then head = head .. perim .. '; ' end               -- FR-70: the days, what is open
  local fix = route_fix(route)
  if fix then head = head .. fix .. '; ' end
  if rdry then head = head .. rdry .. '; ' end                 -- Run 11: the refuge without drink
  if hout then head = head .. hout .. '; ' end                 -- BUG-036: the hospital outside Kern+/the refuge
  if blost then head = head .. blost .. '; ' end               -- BUG-096: a burrow lost its wells or the refuge
  if office then head = head .. office .. '; ' end             -- BUG-055: a vacant office, squads without a leader
  if mws then head = head .. mws .. '; ' end                   -- BUG-117: moodable shops missing
  local tail = '; traps ' .. (traps >= 0 and tostring(traps) or '? (no audit)')
  if #head + #ent + #tail > 200 and open > 0 then              -- the list stands in d.ents: keep the traps visible
    ent = string.format('%d of %d ways in without door or bridge', open, routes)
  end
  return cut(head .. ent .. tail, 200)
end

-- while R0 fails in PEACE: SIEGE_UNREADY (A) at once, then after a game month and UNREADY_WALL_S (UNREADY_NEWS_S when
-- a blocker or an open way in is new); once R1 holds, the record keeps its times (util/cadence quiet)
local function unready(K)
  local now = K.now()
  if (st.lvl or 0) > 0 then
    local u = st.unready
    if u and (#u.ids > 0 or #u.toks > 0) then st.unready, dirty = CAD.quiet(u), true end
    return
  end
  if K.mode() ~= 'PEACE' or now.tick - rt.boot < M.UNREADY_SETTLE then return end
  local fails, ents = rt.fail or {}, rt.ents or {}
  -- FR-70: an open perimeter for escalate_days days: the wake repeats every escalate_every days and 5 real minutes
  -- (news after 5 real minutes), the first time at once
  local esc = rt.pd ~= nil and rt.pd >= pcfg(K, 'escalate_days')
  local toks = fails
  if esc then
    toks = {table.unpack(fails)}
    toks[#toks + 1] = 'escalated'
  end
  local every, wall, nticks, nwall = M.UNREADY_EVERY, M.UNREADY_WALL_S, M.UNREADY_EVERY, M.UNREADY_NEWS_S
  if esc then every, wall, nticks, nwall = pcfg(K, 'escalate_every') * 1200, M.PERIM_WALL_S, 0, M.PERIM_WALL_S end
  local due = CAD.due(st.unready, now, ents, toks, {ticks = nticks, wall_s = nwall})
              or CAD.elapsed(st.unready, now, every, wall)
  if not due then return end
  local a = st.audit
  local traps = a and int(a.min_traps) or -1
  local afails = {}
  for i = 1, math.min(type(a) == 'table' and type(a.fails) == 'table' and #a.fails or 0, 3) do
    afails[i] = cut(a.fails[i], 60)
  end
  local routes, open = rt.routes or -1, rt.open or -1
  local perim = rt.pd and string.format('perimeter OPEN %d d (%s)', rt.pd, rt.pw or '?') or nil
  K.emit('SIEGE_UNREADY', 'A', unready_msg(fails, routes, open, ents, traps, rt.route, rt.rdry, rt.hout, perim, rt.office, rt.blost, rt.mws),
         {fails = fails, afails = afails, routes = routes, open = open, ents = ents, traps = traps,
          age = a and math.max(0, now.tick - a.tick) or -1, rdry = rt.rdry, hout = rt.hout, office = rt.office,
          blost = rt.blost, mws = rt.mws,
          pd = rt.pd, pw = rt.pd and rt.pw or nil})
  st.unready, dirty = CAD.mark(now, ents, toks), true
end

local function refresh(K, why)
  evaluate(K, why)
  unready(K)
  apply_cap(K)
  rt.pub = true
  save(K)
end

---------------------------------------------------------------- public API (CONTRACTS §7)
function M.level(K) return st.lvl or 0 end
-- public (BUG-035): the refuge_dry text of the last evaluation (nil while the refuge has drink or a wet well)
function M.refuge_dry(K) return rt.rdry end
-- public (BUG-049, seal.refuge_trust): what the last Python audit said about the refuge's separation in the worst case
-- (a hatch is no barrier there): {sep = 1|0, age = ticks since that audit}, nil before the first audit
function M.refuge_audit(K)
  local a = st.audit
  if type(a) ~= 'table' or not int(a.tick) then return nil end
  return {sep = a.refuge_sep == 1 and 1 or 0, age = math.max(0, K.now().tick - a.tick)}
end
function M.cap(K) return st.cap or rt.gate_cap or M.CAPS[0] end

---------------------------------------------------------------- verbs
local function bool(v) return type(v) == 'boolean' end

-- CONTRACTS §13 (R6): an audit is accepted only for a snapshot this boot exported with purpose
-- 'audit' (seen as EV:SNAPSHOT_READY) and only once; `by` is checked by kern (VERB_BY)
M.SNAPS_KEPT = 8
-- BUG-043: and what each one covers (snapshot's SNAPSHOT_READY: the default box's margin when it shrank, its shaft
-- columns, the fort pieces an explicit box left out)
M.on['EV:SNAPSHOT_READY'] = function(K, ev)
  local d = type(ev) == 'table' and ev.d
  if type(d) ~= 'table' or d.purpose ~= 'audit' or type(d.id) ~= 'string' then return end
  rt.snaps, rt.cov = rt.snaps or {}, rt.cov or {}
  local list = rt.snaps
  list[#list + 1] = d.id
  rt.cov[d.id] = {margin = type(d.margin) == 'string' and d.margin or nil, cols = int(d.cols) or 0,
                  out = int(d.out) or 0, first = type(d.first) == 'string' and d.first or nil,
                  -- BUG-129: a region box: its parts and the far pieces it dropped (their tiles count as outside)
                  regions = int(d.regions) or 0, drop = int(d.drop) or 0,
                  dropped = type(d.dropped) == 'string' and d.dropped or nil}
  while #list > M.SNAPS_KEPT do rt.cov[table.remove(list, 1)] = nil end
end

local function take_snap(id)
  for i, s in ipairs(rt.snaps or {}) do
    if s == id then
      table.remove(rt.snaps, i)
      local c = rt.cov and rt.cov[id]
      if rt.cov then rt.cov[id] = nil end
      return true, c
    end
  end
  return false
end

-- BUG-043: 'margin 8,8,1, 2 shafts' / 'out 3: explore y451s0b0' (state ready.audit.cov), '' for a full default box;
-- BUG-129: 'drop 1: seal c1a14d660b9fb1de01' first, '7 regions'; a later item only when it fits whole
local function cov_text(c)
  if type(c) ~= 'table' then return '' end
  local t = {}
  if (c.out or 0) > 0 then t[#t + 1] = string.format('out %d: %s', c.out, tostring(c.first)) end
  if (c.drop or 0) > 0 then t[#t + 1] = string.format('drop %d: %s', c.drop, tostring(c.dropped)) end
  if c.margin then t[#t + 1] = 'margin ' .. c.margin end
  if (c.cols or 0) > 0 then t[#t + 1] = string.format('%d shaft%s', c.cols, c.cols == 1 and '' or 's') end
  if (c.regions or 0) > 0 then t[#t + 1] = string.format('%d region%s', c.regions, c.regions == 1 and '' or 's') end
  local s = t[1] and cut(t[1], 40) or ''
  for i = 2, #t do if #s + 2 + #t[i] <= 40 then s = s .. ', ' .. t[i] end end
  return s
end

M.verbs.audit = function(K, args, cmd)
  if type(args.snap) ~= 'string' or not bool(args.ok) or type(args.fails) ~= 'table' or not int(args.min_traps)
     or not (bool(args.bypass) and bool(args.refuge_sep) and bool(args.civ_sep) and bool(args.caverns)) then
    return false, 'bad audit args'
  end
  local known, cov = take_snap(args.snap)
  if not known then return false, 'unknown snap' end
  local fails = {}
  -- BUG-043: an audit of a snapshot that left fort pieces out (an explicit box) proves nothing about them: it fails
  local out = type(cov) == 'table' and (cov.out or 0) > 0
  if out then fails[1] = cut(string.format('coverage: %d piece%s left out (%s)', cov.out, cov.out == 1 and '' or 's',
                                           tostring(cov.first)), 60) end
  for i = 1, math.min(#args.fails, 8 - #fails) do fails[#fails + 1] = cut(args.fails[i], 60) end
  local f = function(b) return b and 1 or 0 end
  st.audit = {tick = K.now().tick, snap = cut(args.snap, 40), ok = (args.ok and not out) and 1 or 0, fails = fails,
              min_traps = math.max(0, int(args.min_traps)), bypass = f(args.bypass),
              refuge_sep = f(args.refuge_sep), civ_sep = f(args.civ_sep), caverns = f(args.caverns),
              cov = cov_text(cov)}
  st.audit_why = nil
  dirty = true
  K.emit('AUDIT', 'B', string.format('audit %s: %d traps min%s', st.audit.ok == 1 and 'ok' or 'failed',
         st.audit.min_traps,
         #fails > 0 and (', ' .. fails[1]) or ''), {ok = st.audit.ok, fails = fails, min_traps = st.audit.min_traps})
  refresh(K, 'audit')
  return true, string.format('audit stored, readiness R%d', st.lvl), {lvl = st.lvl}
end

M.verbs['popcap.lower'] = function(K, args, cmd)
  local cap = int(args.cap)
  if not cap or cap < 0 or cap > 250 then return false, 'cap must be an integer 0..250' end
  local cur = M.ceiling(K, st.lvl or 0)
  if cap < cur then
    st.inbox, dirty = {cap = cap, plan = plan_loaded(K)}, true
    refresh(K, 'inbox')
    return true, string.format('ceiling lowered to %d, max-pop %d', cap, M.cap(K)), {cap = M.cap(K)}
  end
  return true, string.format('ceiling already %d (lower only)', cur), {cap = M.cap(K)}
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.readiness')
  p = type(p) == 'table' and p or {}
  st = {v = 2, lvl = int(p.lvl) or 0, cap = int(p.cap), siege = int(p.siege), audit_req = int(p.audit_req),
        audit_due = int(p.audit_due) or 0, audit_snap = p.audit_snap,
        audit_why = type(p.audit_why) == 'string' and p.audit_why or nil}
  if type(p.audit) == 'table' and int(p.audit.tick) then st.audit = p.audit end
  -- FR-70: the tick the open perimeter began (nil: closed), what was open, the population max-pop is held at, the
  -- bridges seen whole with their levers
  st.pt, st.phold = int(p.pt), int(p.phold)
  st.pw = type(p.pw) == 'string' and p.pw:sub(1, 60) or nil
  for name, v in pairs(type(p.lvok) == 'table' and p.lvok or {}) do
    if type(name) == 'string' and int(v) == 1 then st.lvok = st.lvok or {}; st.lvok[name] = 1 end
  end
  for name, v in pairs(type(p.mws) == 'table' and p.mws or {}) do          -- BUG-117: when a moodable shop was first missed
    if type(name) == 'string' and int(v) then st.mws = st.mws or {}; st.mws[name] = int(v) end
  end
  if type(p.inbox) == 'table' and int(p.inbox.cap) then st.inbox = {cap = int(p.inbox.cap), plan = int(p.inbox.plan)} end
  local u = p.unready                                          -- FR-65: the last SIEGE_UNREADY (util/cadence record)
  if type(u) == 'table' and int(u.t) then
    local function strs(l)
      local r = {}
      for _, v in ipairs(type(l) == 'table' and l or {}) do if type(v) == 'string' then r[#r + 1] = v end end
      return r
    end
    st.unready = {t = int(u.t), w = int(u.w), ids = strs(u.ids), toks = strs(u.toks)}
  end
  rt = {lev = nil, applied = false, pub = false, fail = {}, cv = 0, worn = 0, boot = K.now().tick}
  dirty = false
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  if st.audit_due == 1 or not st.audit_req or now - st.audit_req >= M.AUDIT_EVERY then
    request_audit(K, st.audit_due == 1)
  end
  refresh(K, 'check')
end

function M.state(K)
  if not rt or not rt.pub then return {} end
  local now = K.now().tick
  local a = st.audit
  local r = {lvl = st.lvl or 0, worn = math.max(0, math.min(100, rt.worn or 0)), cv = math.max(0, rt.cv or 0),
             drill_age = rt.pass_tick and math.max(0, now - rt.pass_tick) or -1,
             audit = {ok = rt.audit_ok or 0, age = a and math.max(0, now - a.tick) or -1,
                      min_traps = a and a.min_traps or 0,
                      -- BUG-043: why readiness' last audit request was refused; what the last audit's snapshot covered
                      why = st.audit_why, cov = a and type(a.cov) == 'string' and a.cov ~= '' and a.cov or nil},
             fail = rt.fail,
             open = math.max(-1, rt.open or -1)}                -- FR-65: ways in without door or bridge (-1 unknown)
  if rt.pd then r.pd, r.pw = rt.pd, rt.pw and cut(rt.pw, 60) or nil end    -- FR-70: days open, what is open
  if rt.ents and #rt.ents > 0 then
    local e = {}
    for i = 1, math.min(#rt.ents, 3) do e[i] = rt.ents[i] end
    r.ents = e
  end
  if rt.dhold then r.dhold = rt.dhold end                     -- why no automatic drill starts (drill.hold)
  if rt.dref then r.dref = rt.dref end                        -- BUG-110: drills refused (no O1 / B1), counted once a day
  if rt.route then r.route = rt.route end                     -- the bypass / refuge route the last audit names
  if rt.office then r.office = rt.office end                  -- BUG-055: the vacant office R0 `office` names
  if rt.mws then r.mws = rt.mws end                           -- BUG-117: the moodable shops R0 `mood_ws` names
  return {ready = r, pop = {cap = M.cap(K), gate_cap = rt.gate_cap or M.CAPS[0]}}
end

M.on.MODE = function(K, ev)
  if ev.to == 'SIEGE' or ev.to == 'BREACH' then st.siege, dirty = ev.tick or K.now().tick, true end
  refresh(K, 'mode ' .. tostring(ev.to))
end
M.on['EV:DRILL_RESULT'] = function(K, ev) refresh(K, 'drill') end
M.on['EV:CAVERN_PLUG'] = function(K, ev) refresh(K, 'cavern') end     -- Run 11: a shaft opened or plugged
M.on['EV:PROJECT_STAGE'] = function(K, ev)
  if type(ev.d) == 'table' and ev.d.defense == 1 then rt.lev = nil; request_audit(K, true); save(K) end
end
M.on['EV:PROJECT_DONE'] = function(K, ev)
  rt.lev = nil                                    -- the manifest may have new bridges or levers
  request_audit(K, true)
  refresh(K, 'project')
end

return M
