-- military (WP6): squads A and B (melee) and C (crossbows), Constant training, never Off duty
-- (DESIGN §5.3, CONTRACTS §7). Squads are adopted by name or created once; uniforms are set once;
-- recruits are picked read-only (no work-detail or labor writes: labormanager is the sole owner).
-- Postures (set by siege/drill through military.posture):
--   TRAIN          all squads train (routine 'Constant training', orders cleared)
--   STATION_B1     like TRAIN, the first melee squad stationed at manifest.stations.melee (inside B1)
--   READY_STATION  routine 'Ready'; melee at stations.melee, crossbows at stations.gallery
--   B2_HOLD        routine 'Ready'; every squad holds stations.b2 (the core choke)
-- A squad dfllm creates may come without a leader (act cannot seat one yet [S2]): it is kept for a
-- UI appointment, no further squads are created meanwhile, and a led UI squad of the same name wins.
-- KPIs: worn % = filled uniform specs / uniform slots (worn, never "assigned"; a position without
-- specs counts its whole kit as missing), combat value per soldier = best weapon + shield + armor +
-- dodging skill levels, metal % = soldiers in iron/steel body armor.
-- Reads: squads (world.squads.all, df.squad.find), soldiers and citizens by id only (CONTRACTS §1.4),
-- work details, routines, entity positions. Writes only through K.act.squad_* and K.act.run.
local geom = require('dfllm.util.geom')
local C = require('dfllm.util.contract')

local M = {name = 'military', every = {ticks = 3600}, verbs = {}, on = {}}

M.SQUADS = {{key = 'A', kind = 'melee'}, {key = 'B', kind = 'melee'}, {key = 'C', kind = 'xbow'}}
M.SIZE = 10                 -- DF squads have 10 positions; position 0 is the leader
M.R2_MIN, M.R2_ADULTS = 8, 40   -- R2 needs >= 8 soldiers; aim for it once 8 is <= 20 % of adults
M.XBOW_SHARE = 30           -- % of the army in the crossbow squad (doctrine: 4-5 of 15)
M.FAST, M.SLOW = 600, 3600  -- upkeep cadence outside / in PEACE
M.UNSTICK = 33600           -- uniform-unstick --all --drop --free, monthly, PEACE only (DESIGN §4)
M.ADD_PER_STEP = 5
M.KEEP_EXTRA = 2            -- remove soldiers only when a squad is this far above its target
M.KPI_TTL = 25
M.STATION_R = 3             -- a soldier within 3 tiles (same z) of the station is on station
M.RETRY, M.RETRY_MAX = 1200, 33600
M.NOTIFY_AFTER = 2          -- failed squad creations before DECISION_NEEDED (once per boot)
-- routine names (CONTRACTS §5 squad_routine resolves by name); first exact, then substring
M.ROUTINES = {train = {'constant training', 'constant'}, ready = {'ready', 'ready'}}
M.ROUTINE_FALLBACK = {ready = 'train'}   -- no Ready routine: keep training (never Off duty)

-- uniform specs for act.squad_uniform [S2: act maps them to squad_uniform_spec / an entity template]
local ARMOR = {{cat = 'body', type = 'ARMOR'}, {cat = 'head', type = 'HELM'}, {cat = 'pants', type = 'PANTS'},
               {cat = 'gloves', type = 'GLOVES'}, {cat = 'shoes', type = 'SHOES'}}
local function kit(extra)
  local items = {}
  for _, it in ipairs(ARMOR) do items[#items + 1] = {cat = it.cat, type = it.type} end
  for _, it in ipairs(extra) do items[#items + 1] = it end
  return items
end
M.UNIFORM = {
  melee = {mode = 'replace', mat = 'metal', template = 'metal',
           items = kit({{cat = 'shield', type = 'SHIELD'}, {cat = 'weapon', type = 'WEAPON', choice = 'melee'}})},
  xbow = {mode = 'replace', mat = 'metal', template = 'metal', quiver = true,
          ammo = {type = 'AMMO', subtype = 'ITEM_AMMO_BOLTS', n = 100},
          items = kit({{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_CROSSBOW'}})},
}

-- recruit filter (read-only)
M.TOOL_LABORS = {'MINE', 'CUTWOOD', 'HUNT'}
M.TOOL_DETAILS = {Miners = true, Woodcutters = true, Hunters = true}
M.KEY_LABORS = {'MASON', 'CARPENTER', 'BREWER', 'PLANT', 'COOK', 'MECHANIC', 'DIAGNOSE', 'SMELT',
                'FORGE_WEAPON', 'FORGE_ARMOR'}
M.SQUAD_POSITIONS = {MILITIA_CAPTAIN = true, MILITIA_COMMANDER = true}   -- nobles that may still serve
M.WEAPON_SKILLS = {'AXE', 'SWORD', 'MACE', 'HAMMER', 'SPEAR', 'PIKE', 'WHIP', 'DAGGER', 'CROSSBOW', 'BOW'}
M.CV_SKILLS = {'SHIELD', 'ARMOR', 'DODGING'}
M.METALS = {['INORGANIC:IRON'] = true, ['INORGANIC:STEEL'] = true}
local UNIFORM_CATS = {'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon'}
local WORN_ROLES = {'Worn', 'Weapon', 'Strapped'}

local st      -- persisted m.military: {v, sq = {A = {id, uni, kind, auto}}, posture, pt, unstick}
local rt      -- runtime: retry ticks, applied orders, kpi cache, notified flags
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function pct(a, b) if b <= 0 then return 0 end return (200 * a + b) // (2 * b) end
local function save(K) if dirty then K.persist.set('m.military', st); dirty = false end end
local function now_tick(K) return K.now().tick end

---------------------------------------------------------------- DF reads (all pcall-guarded)
local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return nil
end

local function squad(id)
  if not int(id) then return nil end
  return try(function()
    local s = df.squad.find(id)
    if s and s.entity_id == df.global.plotinfo.group_id then return s end
  end)
end

local function squad_label(s)
  return try(function()
    local a = s.alias ~= nil and dfhack.df2utf(s.alias) or ''
    if a == '' then a = dfhack.military.getSquadName(s.id) or '' end
    return a
  end) or ''
end

-- occupied positions: {{pos = i, unit = u}} (dead units skipped); position 0 is the leader
local function members(s)
  local r = {}
  try(function()
    for i, p in ipairs(s.positions) do
      local hf = p.occupant
      if hf and hf >= 0 then
        local f = df.historical_figure.find(hf)
        local u = f and df.unit.find(f.unit_id)
        if u and not dfhack.units.isDead(u) then r[#r + 1] = {pos = i, unit = u, p = p} end
      end
    end
  end)
  return r
end

local function leader_set(s)
  return try(function() return s.positions[0].occupant >= 0 end) == true
end

local function order_count(s) return try(function() return #s.orders end) or 0 end
local function routine_idx(s) return try(function() return s.cur_routine_idx end) end

-- routine (0-based index into plotinfo.alerts.routines, as act.squad_routine counts) and exact name
local function resolve_routine(which)
  local pats = M.ROUTINES[which]
  local list = try(function()
    local r = {}
    for i, rt_ in ipairs(df.global.plotinfo.alerts.routines) do r[#r + 1] = {i = i, name = dfhack.df2utf(rt_.name)} end
    return r
  end) or {}
  for _, e in ipairs(list) do if e.name:lower() == pats[1] then return e.i, e.name end end
  for _, e in ipairs(list) do if e.name:lower():find(pats[2], 1, true) then return e.i, e.name end end
  return nil
end

local function skill(u, name)
  return try(function()
    local id = df.job_skill[name]
    if id == nil then return 0 end
    return dfhack.units.getNominalSkill(u, id) or 0
  end) or 0
end

-- combat value: best weapon skill + shield + armor + dodging levels (DESIGN §5.3)
function M.cv(u)
  local best = 0
  for _, n in ipairs(M.WEAPON_SKILLS) do best = math.max(best, skill(u, n)) end
  for _, n in ipairs(M.CV_SKILLS) do best = best + skill(u, n) end
  return best
end

local function attr(u, name)
  return try(function() return dfhack.units.getPhysicalAttrValue(u, df.physical_attribute_type[name]) end) or 0
end

local ROLE                         -- set of inventory modes that count as worn
local function roles()
  if not ROLE then
    ROLE = {}
    for _, n in ipairs(WORN_ROLES) do
      local v = try(function() return df.inv_item_role_type[n] end)
      if v ~= nil then ROLE[v] = true end
    end
  end
  return ROLE
end

-- uniform slots of an occupied position: slots, filled, specs. One slot per squad_uniform_spec; it is
-- filled iff the soldier wears one of its items (spec.item, or spec.assigned: gloves and shoes hold a
-- pair; v1 scripts/claude/ausruestung.lua:211, mil.lua:594). Items in assigned_items that no spec holds
-- (v1 "waisen") do not count. A position without specs counts as the kind's whole kit missing.
local function uniform_counts(p, u, kind)
  local on = {}
  try(function()
    local R = roles()
    for _, inv in ipairs(u.inventory) do
      if R[inv.mode] and inv.item then on[inv.item.id] = true end
    end
  end)
  local slots, filled = 0, 0
  try(function()
    for _, c in ipairs(UNIFORM_CATS) do
      for _, sp in ipairs(p.equipment.uniform[c]) do
        slots = slots + 1
        local hit = int(sp.item) ~= nil and on[sp.item] == true
        if not hit and sp.assigned then
          for _, id in ipairs(sp.assigned) do if on[id] then hit = true; break end end
        end
        if hit then filled = filled + 1 end
      end
    end
  end)
  if slots == 0 then return #(M.UNIFORM[kind] or M.UNIFORM.melee).items, 0, 0 end
  return slots, filled, slots
end

local function iron_or_steel(u)
  return try(function()
    local R, armor = roles(), df.item_type.ARMOR
    for _, inv in ipairs(u.inventory) do
      local it = inv.item
      if R[inv.mode] and it and it:getType() == armor then
        local mi = dfhack.matinfo.decode(it)
        if mi and M.METALS[mi:getToken()] then return true end
      end
    end
    return false
  end) == true
end

-- occupied positions (0-based) without any uniform spec, and whether any position has specs
local function bare_positions(s)
  local bare, any = {}, false
  try(function()
    for i, p in ipairs(s.positions) do
      local n = 0
      for _, c in ipairs(UNIFORM_CATS) do n = n + #p.equipment.uniform[c] end
      if n > 0 then any = true elseif p.occupant >= 0 then bare[#bare + 1] = i end
    end
  end)
  return bare, any
end

-- a vacant squad-leader position assignment of the fort entity (MILITIA_COMMANDER/CAPTAIN) [S2]
local function free_assignment()
  return try(function()
    local ent = df.global.plotinfo.main.fortress_entity
    local codes = {}
    for _, p in ipairs(ent.positions.own) do if M.SQUAD_POSITIONS[p.code] then codes[p.id] = true end end
    for _, a in ipairs(ent.positions.assignments) do
      if codes[a.position_id] and a.histfig == -1 and a.squad_id == -1 then return a.id end
    end
  end)
end

---------------------------------------------------------------- recruits (read-only filter)
-- ids of builtin tool-detail members (labormanager equips tools only there)
local function tool_members()
  local set = {}
  try(function()
    for _, wd in ipairs(df.global.plotinfo.labor_info.work_details) do
      local al = wd.allowed_labors
      local tool = false
      for _, l in ipairs(M.TOOL_LABORS) do if al[l] then tool = true end end
      local builtin = wd.flags.no_modify == true or M.TOOL_DETAILS[dfhack.df2utf(wd.name)] == true
      if tool and builtin then for _, id in ipairs(wd.assigned_units) do set[id] = true end end
    end
  end)
  return set
end

local function noble(u)
  return try(function()
    local np = dfhack.units.getNoblePositions(u)
    if not np then return false end
    for _, e in ipairs(np) do
      local code = e.position and e.position.code
      if not M.SQUAD_POSITIONS[code] then return true end
    end
    return false
  end) == true
end

local function labors(u) return try(function() return u.status.labors end) end

-- candidates sorted best first: combat value, then strength + toughness, then id; plus exclusion counts
function M.recruits(K)
  local cu = K.census.u
  local out, why = {}, {tool = 0, sole = 0, noble = 0, mood = 0, child = 0, squad = 0}
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return out, why end
  local adults = {}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      if not dfhack.units.isAdult(u) then why.child = why.child + 1
      else adults[#adults + 1] = u end
    end
  end
  -- sole holders of a key labor
  local count, holder = {}, {}
  for _, u in ipairs(adults) do
    local lab = labors(u)
    if lab then
      for _, l in ipairs(M.KEY_LABORS) do
        if try(function() return lab[l] end) then count[l] = (count[l] or 0) + 1; holder[l] = u.id end
      end
    end
  end
  local sole = {}
  for l, n in pairs(count) do if n == 1 then sole[holder[l]] = true end end
  local tools = tool_members()
  local cand = {}
  for _, u in ipairs(adults) do
    local lab = labors(u)
    local tool_labor = false
    if lab then
      for _, l in ipairs(M.TOOL_LABORS) do if try(function() return lab[l] end) then tool_labor = true end end
    end
    local mood = try(function() return u.mood end)
    if (try(function() return u.military.squad_id end) or -1) >= 0 then why.squad = why.squad + 1
    elseif tools[u.id] or tool_labor then why.tool = why.tool + 1
    elseif sole[u.id] then why.sole = why.sole + 1
    elseif noble(u) then why.noble = why.noble + 1
    elseif mood ~= nil and mood >= 0 then why.mood = why.mood + 1
    else
      cand[#cand + 1] = {id = u.id, cv = M.cv(u), body = attr(u, 'STRENGTH') + attr(u, 'TOUGHNESS')}
    end
  end
  table.sort(cand, function(a, b)
    if a.cv ~= b.cv then return a.cv > b.cv end
    if a.body ~= b.body then return a.body > b.body end
    return a.id < b.id
  end)
  for i, c in ipairs(cand) do out[i] = c.id end
  return out, why
end

---------------------------------------------------------------- targets
-- army share in % from D-12 ('<low>/<high>': low below pop 60, high from 60) and plan.military.pct
function M.share(K, cit)
  local d = tostring((K.cfg.decisions or {})['D-12'] or C.DECISIONS['D-12'])
  local lo, hi = d:match('^(%d+)/(%d+)$')
  lo, hi = tonumber(lo) or 15, tonumber(hi) or 20
  local p = (cit or 0) >= 60 and hi or lo
  local mil = type(K.plan) == 'table' and K.plan.military
  local pp = type(mil) == 'table' and int(mil.pct) or nil
  if pp and pp > p then p = pp end
  return math.tointeger(p) or 15
end

local function phase_no(K)
  local ph = K.view().phase
  return type(ph) == 'string' and tonumber(ph:match('^P(%d)$')) or nil
end

-- wanted squad keys in order: phases P2-P4 only squad A, from P5 all (DESIGN §5.12); none before P2
local function active(K)
  local mil = type(K.plan) == 'table' and type(K.plan.military) == 'table' and K.plan.military or {}
  local sq = type(mil.squads) == 'table' and mil.squads or {}
  local melee = math.min(2, math.max(0, int(sq.melee) or 2))
  local xbow = math.min(1, math.max(0, int(sq.xbow) or 1))
  local ph = phase_no(K)
  if ph and ph < 2 then return {} end
  local r = {}
  for _, s in ipairs(M.SQUADS) do
    if s.kind == 'melee' and melee > 0 then r[#r + 1] = s; melee = melee - 1
    elseif s.kind == 'xbow' and xbow > 0 then r[#r + 1] = s; xbow = xbow - 1 end
  end
  if ph and ph < 5 and #r > 1 then r = {r[1]} end
  return r
end

-- soldiers wanted in total and per squad key
function M.targets(K)
  local cu = K.census.u
  local adults, cit = type(cu) == 'table' and cu.adults or 0, type(cu) == 'table' and cu.cit or 0
  local n = (adults * M.share(K, cit) + 99) // 100
  if adults >= M.R2_ADULTS then n = math.max(n, M.R2_MIN) end
  local act = active(K)
  n = math.min(n, M.SIZE * #act)
  local per = {}
  local melee, xbow = {}, nil
  for _, s in ipairs(act) do per[s.key] = 0; if s.kind == 'melee' then melee[#melee + 1] = s.key else xbow = s.key end end
  if #act == 0 then return 0, per end
  local nx = 0
  if xbow then
    if #melee == 0 then nx = n
    elseif n >= 4 then nx = math.max(2, (n * M.XBOW_SHARE + 50) // 100) end
    nx = math.min(nx, M.SIZE)
    per[xbow] = nx
  end
  local left = n - nx
  for i, k in ipairs(melee) do
    local share = math.min(M.SIZE, (left + (#melee - i)) // (#melee - i + 1))
    per[k] = share
    left = left - share
  end
  if xbow and left > 0 then per[xbow] = math.min(M.SIZE, per[xbow] + left) end   -- melee squads full
  return n, per
end

---------------------------------------------------------------- squads: adopt, create, uniform, fill
local function retry_ok(K, key)
  local t = rt.retry[key]
  return t == nil or now_tick(K) >= t.at
end
local function backoff(K, key)
  local t = rt.retry[key] or {wait = M.RETRY}
  t.at, t.wait = now_tick(K) + t.wait, math.min(M.RETRY_MAX, t.wait * 2)
  rt.retry[key] = t
end
local function cleared(key) rt.retry[key] = nil end

-- an unclaimed fort squad named key (or 'Squad key'); one with a seated leader first, else (unless
-- led_only) the first leaderless one. Fort squads = world.squads.all filtered by entity_id, as
-- hack/scripts/gui/autotraining.lua:30 does; only runs while a squad is missing or leaderless.
local function adopt(K, key, claimed, led_only)
  return try(function()
    local want, alt = key:lower(), nil
    for _, s in ipairs(df.global.world.squads.all) do
      if s.entity_id == df.global.plotinfo.group_id and not claimed[s.id] then
        local l = squad_label(s):lower()
        if l == want or l == 'squad ' .. want then
          if leader_set(s) then return s end
          alt = alt or s
        end
      end
    end
    if not led_only then return alt end
  end)
end

-- squads cannot be made or led in game yet [S2]: tell Gordon once per boot which UI action helps
local function stuck(K)
  rt.create_fails = rt.create_fails + 1
  if rt.create_fails < M.NOTIFY_AFTER or rt.notified then return end
  rt.notified = true
  local lead, make = {}, {}
  for _, sp in ipairs(active(K)) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    if s and not leader_set(s) then lead[#lead + 1] = sp.key
    elseif not s then make[#make + 1] = sp.key .. (sp.kind == 'xbow' and ' (crossbows)' or ' (melee)') end
  end
  local parts = {}
  if #lead > 0 then
    parts[#parts + 1] = 'appoint a militia commander/captain (nobles screen) to lead squad ' .. table.concat(lead, ', ')
  end
  if #make > 0 then
    parts[#parts + 1] = 'create squads named ' .. table.concat(make, ', ') .. ' with a leader (squads screen)'
  end
  if #parts == 0 then parts[1] = 'check the squads screen' end
  local q = table.concat(parts, '; ') .. '. dfllm then fills, equips and trains them (it cannot seat leaders [S2])'
  local msg = 'squads [S2]: ' .. parts[1]
  K.emit('DECISION_NEEDED', 'A', #msg > 200 and msg:sub(1, 200) or msg, {id = 'squads', q = q})
end

local function claimed_ids()
  local r = {}
  for _, e in pairs(st.sq) do if int(e.id) then r[e.id] = true end end
  return r
end

-- a squad dfllm created still has no leader: make no more until it has one (each would be leaderless)
local function waiting_for_leader()
  for _, e in pairs(st.sq) do
    local s = e.auto == 1 and squad(e.id)
    if s and not leader_set(s) then return true end
  end
  return false
end

-- the squad of key k, adopted or created; nil if none yet. recruits() -> shared candidate list
local function ensure_squad(K, spec, recruits)
  local k = spec.key
  local e = st.sq[k]
  local s = e and squad(e.id)
  if s and not leader_set(s) and #members(s) == 0 then
    -- addToSquad fails while the leader slot is vacant (Lua API.txt:1993): prefer a led squad of
    -- the same name, e.g. one made in the UI after ours (squads cannot be deleted, v1 BUG-425)
    local alt = adopt(K, k, claimed_ids(), true)
    if alt then
      K.log('info', 'military: squad %s: id %d has a leader, leaving leaderless id %d', k, alt.id, s.id)
      st.sq[k], dirty = {id = alt.id, kind = spec.kind, uni = 0}, true
      return alt
    end
  end
  if s then return s end
  if e then st.sq[k], dirty = nil, true end           -- disbanded in the UI: forget it
  s = adopt(K, k, claimed_ids())
  if s then
    st.sq[k], dirty = {id = s.id, kind = spec.kind, uni = 0}, true
    K.log('info', 'military: adopted squad %s (id %d)', k, s.id)
    return s
  end
  if waiting_for_leader() or not retry_ok(K, 'create' .. k) or #recruits() == 0 then return nil end
  local leader = table.remove(recruits(), 1)
  local ok, id = K.act.squad_create(k, {assignment_id = free_assignment(), leader = leader, kind = spec.kind})
  s = ok and squad(id)
  if not s then
    backoff(K, 'create' .. k)
    stuck(K)
    return nil
  end
  cleared('create' .. k)
  st.sq[k], dirty = {id = s.id, kind = spec.kind, uni = 0, auto = 1}, true
  if leader_set(s) then
    K.log('info', 'military: created squad %s (id %d, leader %d)', k, s.id, leader)
  else
    table.insert(recruits(), 1, leader)               -- not seated: still a candidate
    K.log('warn', 'military: created squad %s (id %d) without a leader [S2]', k, s.id)
    stuck(K)                                          -- not transient: makeSquad seats nobody
  end
  return s
end

-- every occupied position needs uniform specs (checked each upkeep). The first uniform goes to the
-- whole squad; later only to the bare positions (spec.positions, 0-based), so a uniform chosen in the
-- UI is kept. e.uni = 1 while no occupied position is bare.
local function ensure_uniform(K, k, s)
  local e = st.sq[k]
  local bare, any = bare_positions(s)
  local uni = #bare == 0 and 1 or 0
  if uni == 1 then cleared('uni' .. k)
  elseif retry_ok(K, 'uni' .. k) then
    local spec = M.UNIFORM[e.kind] or M.UNIFORM.melee
    if any then
      local c = {}
      for key, v in pairs(spec) do c[key] = v end
      c.positions = bare
      spec = c
    end
    if K.act.squad_uniform(s.id, spec) then uni = 1 end
    backoff(K, 'uni' .. k)                            -- re-checked next upkeep either way
  end
  if e.uni ~= uni then e.uni, dirty = uni, true end
end

local function fill(K, k, s, want, recruits)
  local mem = members(s)
  local n = #mem
  if n < want and retry_ok(K, 'add' .. k) and leader_set(s) then
    local added = 0
    while n < want and added < M.ADD_PER_STEP and #recruits() > 0 do
      local uid = table.remove(recruits(), 1)
      if K.act.squad_add(s.id, uid) then n, added = n + 1, added + 1
      else backoff(K, 'add' .. k); break end
    end
  elseif n > want + M.KEEP_EXTRA and K.mode() == 'PEACE' then
    local worst                                  -- lowest combat value, never the leader
    for _, m in ipairs(mem) do
      if m.pos ~= 0 and (worst == nil or M.cv(m.unit) < M.cv(worst.unit)) then worst = m end
    end
    if worst then K.act.squad_remove(s.id, worst.unit.id) end
  end
end

---------------------------------------------------------------- postures and orders
local function station_of(P, kind, first_melee, stations)
  local melee, gallery, b2 = stations.melee, stations.gallery, stations.b2
  if P == 'STATION_B1' then return 'train', first_melee and melee or nil end
  if P == 'READY_STATION' then return 'ready', kind == 'xbow' and (gallery or melee) or melee end
  if P == 'B2_HOLD' then return 'ready', b2 or melee end
  return 'train', nil
end

local function first_melee_key()
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and sp.kind == 'melee' and squad(e.id)
    if s and #members(s) > 0 then return sp.key end
  end
end

local function posp(p)
  if type(p) ~= 'table' then return nil end
  local x, y, z = int(p[1] or p.x), int(p[2] or p.y), int(p[3] or p.z)
  if not (x and y and z) then return nil end
  return geom.pos(x, y, z)
end

-- bring one squad to the posture; force = re-issue even if it looks applied. Returns ok.
local function apply_squad(K, k, force)
  local e = st.sq[k]
  local s = e and squad(e.id)
  if not s then return true end
  local man = K.manifest()
  local stations = type(man.stations) == 'table' and man.stations or {}
  local which, pos = station_of(st.posture, e.kind, k == first_melee_key(), stations)
  pos = posp(pos)
  local ok = true
  local idx, name = resolve_routine(which)
  if not idx and M.ROUTINE_FALLBACK[which] then idx, name = resolve_routine(M.ROUTINE_FALLBACK[which]) end
  if not idx then
    if not rt.warned_routine then rt.warned_routine = true; K.log('warn', 'military: no routine named %s', which) end
    ok = false
  elseif force or routine_idx(s) ~= idx then
    ok = K.act.squad_routine(s.id, name) and ok
  end
  local sig = pos and string.format('station:%d,%d,%d', pos.x, pos.y, pos.z) or 'train'
  local cur = rt.order[k]
  local held = cur and (cur:sub(1, 5) == 'kill:' or cur:sub(1, 7) == 'sortie:') and order_count(s) > 0
  if held and not force then return ok end           -- a kill order or an approved sortie runs
  local drift = (pos and order_count(s) == 0) or (not pos and order_count(s) > 0)
  if force or cur ~= sig or drift then
    local r = K.act.squad_order(s.id, pos and {kind = 'station', pos = pos} or {kind = 'train'})
    if r then rt.order[k] = sig else ok = false end
  end
  rt.station[k] = pos
  return ok
end

-- public (CONTRACTS §7): idempotent; a new posture re-issues orders and ends sorties.
-- force = re-issue even an unchanged posture (siege.withdraw's fallback, WP5)
function M.posture(K, P, force)
  local valid = false
  for _, p in ipairs(C.POSTURES) do if p == P then valid = true end end
  if not valid then return false, 'unknown posture ' .. tostring(P) end
  local changed = st.posture ~= P
  if changed then st.posture, st.pt, dirty = P, now_tick(K), true end
  local ok = true
  for _, sp in ipairs(M.SQUADS) do ok = apply_squad(K, sp.key, changed or force == true) and ok end
  rt.kpi = nil
  save(K)
  return ok
end

---------------------------------------------------------------- kill orders (killboxes only)
local function on_stair(man, e)
  local stairs = type(man.stairs) == 'table' and man.stairs or {}
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(stairs[kind]) == 'table' and stairs[kind] or {}) do
      if e.x == c[1] and e.y == c[2] and e.z >= c[3] and e.z <= c[4] then return true end
    end
  end
  return false
end

local SHAFT = {['<'] = true, ['>'] = true, X = true, _ = true}
local function shaft(K, e)
  local ok, t = K.call('snapshot', 'tile', e.x, e.y, e.z)
  return ok and type(t) == 'table' and SHAFT[t.c] == true
end

local function in_box(man, e, box_id)
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if (box_id == nil or kb.id == box_id) and type(kb.bbox) == 'table' and geom.in_bbox(e, kb.bbox) then return true end
  end
  return false
end

-- visible hostiles (K.census.h.list) inside a killbox and not on a stair or shaft tile
local function valid_targets(K, ids, box_id)
  local h, man = K.census.h, K.manifest()
  local by = {}
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do by[e.id] = e end
  local r = {}
  for _, id in ipairs(ids) do
    local e = by[id]
    if e and in_box(man, e, box_id) and not on_stair(man, e) and not shaft(K, e) then r[#r + 1] = id end
  end
  table.sort(r)
  return r
end

local function squads_of(kind)
  local r = {}
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and (kind == nil or e.kind == kind) and squad(e.id)
    if s and #members(s) > 0 then r[#r + 1] = {key = sp.key, s = s} end
  end
  return r
end

-- public: kill order for the crossbow squads (they fire from the roofed gallery; melee never leave B1).
-- kill({}) withdraws the running kill orders: those squads get their posture orders again (siege calls
-- it when no target is left in a kill box). A non-empty list without a valid target is refused.
function M.kill(K, ids)
  if type(ids) ~= 'table' then return false, 0 end
  if #ids == 0 then
    local ok = true
    for _, sp in ipairs(M.SQUADS) do
      local cur = rt.order[sp.key]
      if cur and cur:sub(1, 5) == 'kill:' then
        rt.order[sp.key] = nil
        ok = apply_squad(K, sp.key, true) and ok
      end
    end
    rt.kpi = nil
    return ok, 0
  end
  local t = valid_targets(K, ids)
  if #t == 0 then return false, 0 end
  local sq = squads_of('xbow')
  if #sq == 0 then return false, 0 end
  local sig = 'kill:' .. table.concat(t, ',')
  local n = 0
  for _, q in ipairs(sq) do
    if K.act.squad_order(q.s.id, {kind = 'kill', units = t}) then rt.order[q.key], n = sig, n + 1 end
  end
  rt.kpi = nil
  return n > 0, #t
end

-- inbox squad.sortie (approval checked by kern): kill the visible hostiles in a killbox, else move there
M.verbs['squad.sortie'] = function(K, args, cmd)
  local k = args.squad
  local e = type(k) == 'string' and st.sq[k]
  local s = e and squad(e.id)
  if not s or #members(s) == 0 then return false, 'no squad ' .. tostring(k) end
  local target, order, what = args.target, nil, nil
  if type(target) == 'string' then
    local man = K.manifest()
    local box
    for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do if kb.id == target then box = kb end end
    if not box then return false, 'no killbox ' .. target end
    local ids = {}
    for _, h in ipairs(type(K.census.h) == 'table' and K.census.h.list or {}) do ids[#ids + 1] = h.id end
    local t = valid_targets(K, ids, target)
    if #t > 0 then order, what = {kind = 'kill', units = t}, 'kill ' .. #t .. ' in ' .. target
    else order, what = {kind = 'station', pos = geom.bbox_center(box.bbox)}, 'move to ' .. target end
  else
    local p = posp(target)
    if not p then return false, 'target must be a killbox id or [x,y,z]' end
    order, what = {kind = 'station', pos = p}, string.format('move to %d,%d,%d', p.x, p.y, p.z)
  end
  local ok, err = K.act.squad_order(s.id, order)
  if not ok then return false, 'order failed: ' .. tostring(err) end
  rt.order[k] = 'sortie:' .. tostring(cmd and cmd.id or '?')
  rt.kpi = nil
  return true, 'sortie ' .. k .. ': ' .. what
end

---------------------------------------------------------------- KPIs
local function compute(K)
  local k = {squads = 0, soldiers = 0, worn = 0, cv = 0, metal_pct = 0, on_station = 0}
  local slots, worn, specs, cv, metal = 0, 0, 0, 0, 0
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    if s then
      local mem = members(s)
      if #mem > 0 then k.squads = k.squads + 1 end
      local spos = rt.station[sp.key]
      for _, m in ipairs(mem) do
        local u = m.unit
        k.soldiers = k.soldiers + 1
        local a, b, c = uniform_counts(m.p, u, e.kind)
        slots, worn, specs = slots + a, worn + b, specs + c
        cv = cv + M.cv(u)
        if iron_or_steel(u) then metal = metal + 1 end
        if spos then
          local up = try(function() return {x = u.pos.x, y = u.pos.y, z = u.pos.z} end)
          if up and up.z == spos.z and geom.dist(up, spos) <= M.STATION_R then k.on_station = k.on_station + 1 end
        end
      end
    end
  end
  k.worn = pct(worn, slots)
  k.metal_pct = pct(metal, k.soldiers)
  if k.soldiers > 0 then k.cv = (2 * cv + k.soldiers) // (2 * k.soldiers) end
  k.slots, k.specs = slots, specs
  return k
end

-- public (CONTRACTS §7): {squads, soldiers, worn, cv, metal_pct, on_station} (+ slots = uniform
-- slots incl. the kits of positions without specs, specs = uniform specs that exist)
function M.kpi(K)
  local now = now_tick(K)
  if not rt.kpi or now - rt.kpi_tick >= M.KPI_TTL then rt.kpi, rt.kpi_tick = compute(K), now end
  local r = {}
  for key, v in pairs(rt.kpi) do r[key] = v end
  return r
end

-- squad ids by key (for drill/readiness and tests)
function M.squads(K)
  local r = {}
  for key, e in pairs(st.sq) do if squad(e.id) then r[key] = e.id end end
  return r
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.military')
  p = type(p) == 'table' and p or {}
  st = {v = 2, sq = {}, posture = type(p.posture) == 'string' and p.posture or nil, pt = int(p.pt),
        unstick = int(p.unstick)}
  for _, sp in ipairs(M.SQUADS) do
    local e = type(p.sq) == 'table' and p.sq[sp.key]
    if type(e) == 'table' and int(e.id) then
      st.sq[sp.key] = {id = int(e.id), kind = sp.kind, uni = int(e.uni) == 1 and 1 or 0,
                       auto = int(e.auto) == 1 and 1 or nil}
    end
  end
  rt = {retry = {}, order = {}, station = {}, kpi = nil, kpi_tick = 0, create_fails = 0}
  dirty = false
  M.every = {ticks = K.mode() == 'PEACE' and M.SLOW or M.FAST}
end

function M.step(K, budget, ctx)
  local now = now_tick(K)
  local mode = K.mode()
  local want_every = mode == 'PEACE' and M.SLOW or M.FAST
  if M.every.ticks ~= want_every then M.every = {ticks = want_every} end
  if type(K.census.u) ~= 'table' then return end
  local soldiers = rt.kpi and rt.kpi.soldiers or 0
  if mode == 'PEACE' and soldiers > 0 and (st.unstick == nil or now - st.unstick >= M.UNSTICK) then
    K.act.run('uniform-unstick', '--all', '--drop', '--free')
    st.unstick, dirty = now, true
  end
  local _, per = M.targets(K)
  local list
  local function recruits() list = list or M.recruits(K); return list end   -- only when needed
  for _, sp in ipairs(M.SQUADS) do
    local want = per[sp.key] or 0
    local e = st.sq[sp.key]
    if want > 0 or e then
      local s = ensure_squad(K, sp, recruits)
      if s then
        ensure_uniform(K, sp.key, s)
        if want > 0 and not leader_set(s) then stuck(K) end      -- addToSquad needs a leader
        fill(K, sp.key, s, want, recruits)
      end
    end
  end
  if st.posture == nil then st.posture, st.pt, dirty = 'TRAIN', now, true end
  for _, sp in ipairs(M.SQUADS) do apply_squad(K, sp.key, false) end   -- drift only
  rt.kpi, rt.kpi_tick = compute(K), now
  save(K)
end

function M.state(K)
  local k = rt and rt.kpi
  if not k then return {} end
  return {mil = {squads = k.squads, soldiers = k.soldiers, worn = k.worn, cv = k.cv,
                 metal_pct = k.metal_pct, on_station = k.on_station}}
end

M.on.MODE = function(K, ev)
  local want = ev.to == 'PEACE' and M.SLOW or M.FAST
  if M.every.ticks ~= want then M.every = {ticks = want} end
end

return M
