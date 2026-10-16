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
-- (bp.topo.audit ok=false), bypass, refuge_sep, civ_sep, caverns (its flags), no_kern, no_refuge (burrows),
-- no_outer, no_inner (no manifest bridge of that role), bridge:<B> (gate does not know it), levers:<B> (< 2 linked).
-- FR-65 siege readiness gate: while R0 fails in PEACE, SIEGE_UNREADY (A) names the blockers, the ways in without a
-- door or bridge (seal.entrance_doors) and the trap count of the last audit; first at once (2 days after a load),
-- then again after a game month and 30 real minutes, or 10 when it got worse (util/cadence).
-- Run 10 (the bypass finding stood for months, the 41 traps stayed unused): the last audit's first attacker-route
-- finding (`bypass: wall x,y,z floor -> X`, `refuge: on the attack path, wall ...`) stands in SIEGE_UNREADY with its
-- fix (`seal at=audit` builds the named wall) and in the state (ready.route) for status and `dfllm plan check`.
local geom = require('dfllm.util.geom')
local CAD = require('dfllm.util.cadence')

local M = {name = 'readiness', every = {ticks = 1200}, verbs = {}, on = {}}

M.CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
M.SIEGE_TRIGGER = 80     -- difficulty "enemy population trigger" [S10: read it]; R2 ceiling = trigger - 5
M.DRILL_VALID = 100800   -- a passed drill counts for one season
M.AUDIT_VALID = 100800   -- an audit counts for one season
M.AUDIT_EVERY = 33600    -- re-audit monthly
M.AUDIT_GAP = 1200       -- at most one audit request per day
M.LEVERS_EVERY = 33600
M.MIN_LEVERS, M.TRAPS, M.METAL, M.R2_SOLDIERS = 2, 30, 20, 8
M.STOCK_HYST = 90        -- % of a stock minimum that keeps R2 once reached (no flapping)
M.PAD = {8, 16, 1}       -- audit bbox margin around the manifest geometry (live L7: a bedrooms block 8 tiles past the geometry ended on the box edge and read as a way in)
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
  local fails, roles = {}, {}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 then
      roles[b.role or '?'] = true
      local ok, s = K.call('gate', 'state', name)
      if not ok or s == 'unknown' then fails[#fails + 1] = 'bridge:' .. name end
      local n = 0
      for _, p in ipairs(type(b.levers) == 'table' and b.levers or {}) do
        if type(p) == 'table' and lever_ok(p, b.fp) then n = n + 1 end
      end
      if n < M.MIN_LEVERS then fails[#fails + 1] = 'levers:' .. name end
    end
  end
  if not roles.outer then table.insert(fails, 1, 'no_outer') end
  if not roles.inner then table.insert(fails, 1, 'no_inner') end
  return {tick = K.now().tick, fails = fails}
end

---------------------------------------------------------------- audit requests
local function grow(bb, p)
  if type(p) ~= 'table' or #p < 3 then return bb end
  local x0, y0, z0 = p[1], p[2], p[3]
  local x1, y1, z1 = p[4] or x0, p[5] or y0, p[6] or z0
  if not bb then return {x0, y0, z0, x1, y1, z1} end
  return {math.min(bb[1], x0), math.min(bb[2], y0), math.min(bb[3], z0),
          math.max(bb[4], x1), math.max(bb[5], y1), math.max(bb[6], z1)}
end

-- union of the manifest geometry plus a margin (nil: let snapshot choose)
function M.audit_bbox(man)
  local bb
  for _, b in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    bb = grow(bb, b.fp)
    for _, l in ipairs(type(b.levers) == 'table' and b.levers or {}) do bb = grow(bb, l) end
  end
  for _, list in pairs(type(man.zones) == 'table' and man.zones or {}) do
    for _, z in ipairs(list) do bb = grow(bb, z) end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do bb = grow(bb, kb.bbox) end
  for _, p in pairs(type(man.stations) == 'table' and man.stations or {}) do bb = grow(bb, p) end
  for _, p in ipairs(type(man.edge) == 'table' and man.edge or {}) do bb = grow(bb, p) end
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(man.stairs) == 'table' and type(man.stairs[kind]) == 'table' and man.stairs[kind] or {}) do
      bb = grow(bb, {c[1], c[2], c[3], c[1], c[2], c[4]})
    end
  end
  if type(man.refuge) == 'table' then bb = grow(bb, man.refuge.anchor) end
  bb = grow(grow(bb, man.pit), man.depot)
  if not bb then return nil end
  local P = M.PAD
  return {math.max(0, bb[1] - P[1]), math.max(0, bb[2] - P[2]), math.max(0, bb[3] - P[3]),
          bb[4] + P[1], bb[5] + P[2], bb[6] + P[3]}
end

local function request_audit(K, force)
  local now = K.now().tick
  if not QUIET_MODES[K.mode()] then st.audit_due, dirty = 1, true; return end
  if st.audit_req and now - st.audit_req < (force and M.AUDIT_GAP or M.AUDIT_EVERY) then
    if force then st.audit_due, dirty = 1, true end
    return
  end
  local man = K.manifest()
  local bbox = M.audit_bbox(man)
  if not bbox then return end                                 -- nothing built yet
  -- live L2: a bedrooms dig still in progress ran past the box edge; the audit took the cut-off corridor
  -- for a way in (bypass) and readiness fell R1 -> R0. Running projects are inside the box too.
  local okb, boxes = K.call('runner', 'bboxes')
  for _, b in ipairs(okb and type(boxes) == 'table' and boxes or {}) do
    if type(b) == 'table' and #b == 6 then
      local P = M.PAD
      bbox = {math.min(bbox[1], math.max(0, b[1] - P[1])), math.min(bbox[2], math.max(0, b[2] - P[2])),
              math.min(bbox[3], math.max(0, b[3] - P[3])), math.max(bbox[4], b[4] + P[1]),
              math.max(bbox[5], b[5] + P[2]), math.max(bbox[6], b[6] + P[3])}
    end
  end
  st.audit_req, st.audit_due, dirty = now, 0, true
  local ok, ok2, id = K.call('snapshot', 'export', {purpose = 'audit', bbox = bbox})
  if ok and ok2 then st.audit_snap = tostring(id)
  else K.log('warn', 'readiness: audit snapshot not exported: %s', tostring(ok and id or ok2)) end
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

local function evaluate(K, why)
  local now = K.now().tick
  local man = K.manifest()
  local cu = K.census.u
  local okm, kpi = K.call('military', 'kpi')
  kpi = okm and type(kpi) == 'table' and kpi or nil
  -- R1
  local f1 = audit_fails(K, now)
  rt.audit_ok = #f1 == 0 and 1 or 0
  local kern, refuge = burrow_names(man)
  if not dfhack.burrows.findByName(kern) then f1[#f1 + 1] = 'no_kern' end
  if not dfhack.burrows.findByName(refuge) then f1[#f1 + 1] = 'no_refuge' end
  if not rt.lev or now - rt.lev.tick >= M.LEVERS_EVERY then rt.lev = check_levers(K, man) end
  for _, f in ipairs(rt.lev.fails) do f1[#f1 + 1] = f end
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
  rt.routes, rt.open, rt.ents = entrances(K)                       -- FR-65
  local okd, hold = K.call('drill', 'hold')
  rt.dhold = okd and type(hold) == 'string' and cut(hold, 24) or nil
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

local function unready_msg(fails, routes, open, ents, traps, route)
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
  local fix = route_fix(route)
  if fix then head = head .. fix .. '; ' end
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
  local due = CAD.due(st.unready, now, ents, fails, {ticks = M.UNREADY_EVERY, wall_s = M.UNREADY_NEWS_S})
              or CAD.elapsed(st.unready, now, M.UNREADY_EVERY, M.UNREADY_WALL_S)
  if not due then return end
  local a = st.audit
  local traps = a and int(a.min_traps) or -1
  local afails = {}
  for i = 1, math.min(type(a) == 'table' and type(a.fails) == 'table' and #a.fails or 0, 3) do
    afails[i] = cut(a.fails[i], 60)
  end
  local routes, open = rt.routes or -1, rt.open or -1
  K.emit('SIEGE_UNREADY', 'A', unready_msg(fails, routes, open, ents, traps, rt.route),
         {fails = fails, afails = afails, routes = routes, open = open, ents = ents, traps = traps,
          age = a and math.max(0, now.tick - a.tick) or -1})
  st.unready, dirty = CAD.mark(now, ents, fails), true
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
function M.cap(K) return st.cap or rt.gate_cap or M.CAPS[0] end

---------------------------------------------------------------- verbs
local function bool(v) return type(v) == 'boolean' end

-- CONTRACTS §13 (R6): an audit is accepted only for a snapshot this boot exported with purpose
-- 'audit' (seen as EV:SNAPSHOT_READY) and only once; `by` is checked by kern (VERB_BY)
M.SNAPS_KEPT = 8
M.on['EV:SNAPSHOT_READY'] = function(K, ev)
  local d = type(ev) == 'table' and ev.d
  if type(d) ~= 'table' or d.purpose ~= 'audit' or type(d.id) ~= 'string' then return end
  rt.snaps = rt.snaps or {}
  local list = rt.snaps
  list[#list + 1] = d.id
  while #list > M.SNAPS_KEPT do table.remove(list, 1) end
end

local function take_snap(id)
  for i, s in ipairs(rt.snaps or {}) do
    if s == id then table.remove(rt.snaps, i); return true end
  end
  return false
end

M.verbs.audit = function(K, args, cmd)
  if type(args.snap) ~= 'string' or not bool(args.ok) or type(args.fails) ~= 'table' or not int(args.min_traps)
     or not (bool(args.bypass) and bool(args.refuge_sep) and bool(args.civ_sep) and bool(args.caverns)) then
    return false, 'bad audit args'
  end
  if not take_snap(args.snap) then return false, 'unknown snap' end
  local fails = {}
  for i = 1, math.min(#args.fails, 8) do fails[i] = cut(args.fails[i], 60) end
  local f = function(b) return b and 1 or 0 end
  st.audit = {tick = K.now().tick, snap = cut(args.snap, 40), ok = f(args.ok), fails = fails,
              min_traps = math.max(0, int(args.min_traps)), bypass = f(args.bypass),
              refuge_sep = f(args.refuge_sep), civ_sep = f(args.civ_sep), caverns = f(args.caverns)}
  dirty = true
  K.emit('AUDIT', 'B', string.format('audit %s: %d traps min%s', args.ok and 'ok' or 'failed', st.audit.min_traps,
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
        audit_due = int(p.audit_due) or 0, audit_snap = p.audit_snap}
  if type(p.audit) == 'table' and int(p.audit.tick) then st.audit = p.audit end
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
                      min_traps = a and a.min_traps or 0},
             fail = rt.fail,
             open = math.max(-1, rt.open or -1)}                -- FR-65: ways in without door or bridge (-1 unknown)
  if rt.ents and #rt.ents > 0 then
    local e = {}
    for i = 1, math.min(#rt.ents, 3) do e[i] = rt.ents[i] end
    r.ents = e
  end
  if rt.dhold then r.dhold = rt.dhold end                     -- why no automatic drill starts (drill.hold)
  if rt.route then r.route = rt.route end                     -- the bypass / refuge route the last audit names
  return {ready = r, pop = {cap = M.cap(K), gate_cap = rt.gate_cap or M.CAPS[0]}}
end

M.on.MODE = function(K, ev)
  if ev.to == 'SIEGE' or ev.to == 'BREACH' then st.siege, dirty = ev.tick or K.now().tick, true end
  refresh(K, 'mode ' .. tostring(ev.to))
end
M.on['EV:DRILL_RESULT'] = function(K, ev) refresh(K, 'drill') end
M.on['EV:PROJECT_STAGE'] = function(K, ev)
  if type(ev.d) == 'table' and ev.d.defense == 1 then rt.lev = nil; request_audit(K, true); save(K) end
end
M.on['EV:PROJECT_DONE'] = function(K, ev)
  rt.lev = nil                                    -- the manifest may have new bridges or levers
  request_audit(K, true)
  refresh(K, 'project')
end

return M
