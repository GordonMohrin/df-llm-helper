-- military (WP6): squads A and B (melee) and C (crossbows), Constant training, never Off duty
-- (DESIGN §5.3, CONTRACTS §7). Squads are adopted by name or created once; uniforms are set once;
-- recruits are picked read-only (no work-detail or labor writes: labormanager and, for the builtin tool
-- details, economy own them).
-- Postures (set by siege/drill through military.posture):
--   TRAIN          all squads train (routine 'Constant training', orders cleared)
--   STATION_B1     like TRAIN, the first melee squad stationed at manifest.stations.melee (inside B1)
--   READY_STATION  routine 'Ready'; melee at stations.melee, crossbows at stations.gallery
--   B2_HOLD        routine 'Ready'; every squad holds stations.b2 (the core choke)
--   READY_IN       routine 'Ready'; every squad, crossbows too, at the inner station (BUG-029, SIEGE between intake
--                  waves): stations.melee, or stations.b2 while a core bridge (B2) is not down, so the soldiers stand
--                  on the side of the fort that holds the drink and food (live Run 10: gallery 123,123,122 and melee
--                  130,128,122 lay between O1 and B2, recruits there were cut off from drink for weeks)
--   INTAKE         routine 'Ready'; melee in the killing field (stations.field, else the first killbox's centre),
--                  crossbows in the gallery (else the field); only while siege runs an intake wave
--   CORE           routine 'Ready'; every squad, crossbows too, at the core station (BUG-030, siege's deep defense:
--                  building destroyers in sight, an army over stations.core_ratio x the soldiers, weak squads):
--                  stations.core (the core level next to the civilians' stair to the refuge), else stations.b2, else
--                  stations.melee; never the corridor or the killing field (Run 10 y421: 19 recruits at the melee and
--                  gallery stations between O1 and B2 died first)
-- STATION_B1 uses the inner station too (stations.b2 while B2 is not down). An approved sortie order is held (no
-- posture re-assert replaces it) until siege releases the squad (hold_order / release).
-- BUG-032 (Run 11 y432: GATE_FAIL B2 'not up after 908 ticks', squad 104 stationed next to B2 at fortcore's
-- stations.b2, one tile behind its footprint, held the BREACH raise): a posture names a chain of stations; the first
-- one that lies more than gate.MARGIN + stations.spread (config/reflex.json, 1) tiles from every manifest bridge
-- footprint on its level is taken, else it moves to the nearest revealed plain floor on the inner side of the
-- footprints that hold it (dfllm.stations), else the next station of the chain (entries marked alt only after one
-- failed: core, the core level's centre z4). STATION_MOVED (B) and a kern.log line name the old and the new station.
-- Soldiers standing at their squad's station who still hold a raise (a crowd of 30 on a landing) get their squad
-- re-stationed at once (M.restation, asked by siege with gate.holds()): a station whose crowd stays out of the ring,
-- on the inner side of that bridge, else the next of the chain; military keeps it for the posture (rt.over).
-- Squads are created with a leader (act.squad_create + act.squad_leader, the squads screen [S2, live L2]); a
-- squad left without one (seating refused) gets the next recruit as leader with backoff, no further squads
-- are created meanwhile, Gordon is told once (DECISION_NEEDED squads), and a led UI squad of the same name wins.
-- KPIs: worn % = filled uniform specs / uniform slots (worn, never "assigned"; a position without
-- specs counts its whole kit as missing), combat value per soldier = best weapon + shield + armor +
-- dodging skill levels, metal % = soldiers in iron/steel body armor.
-- Reads: squads (world.squads.all, df.squad.find), soldiers and citizens by id only (CONTRACTS §1.4),
-- work details, routines, entity positions. Writes only through K.act.squad_* and K.act.run, and since Run 9
-- (FR-46) K.act.item_flag: after a siege the invaders' metal gear lay forbidden (DF's standing order forbids
-- the items of the dead: 22 steel/bronze/iron pieces on the surface, 29 inside) while worn read 0 %. In PEACE,
-- and in RECOVERY with no hostile in sight, forbidden metal weapons, armor, shields and ammo nobody holds are
-- unforbidden on revealed tiles the citizens can reach (snapshot.tile / snapshot.far), at most LOOT.per_run a
-- run; the fort's weapon and armor stockpiles (the armory) take them and the uniforms pick them. mil.free (state,
-- status) counts the free metal gear per category.
local geom = require('dfllm.util.geom')
local C = require('dfllm.util.contract')
local SL = require('dfllm.stations')       -- BUG-032: stations clear of the bridge footprints (library, no module)
local ROT = require('dfllm.rotation')      -- FR-79: window edges, fairness ranking, swap plan (library, no module)

local M = {name = 'military', every = {ticks = 3600}, verbs = {}, on = {}}

M.SQUADS = {{key = 'A', kind = 'melee'}, {key = 'B', kind = 'melee'}, {key = 'C', kind = 'xbow'}}
M.SIZE = 10                 -- DF squads have 10 positions; position 0 is the leader
M.R2_MIN, M.R2_ADULTS = 8, 40   -- R2 needs >= 8 soldiers; aim for it once 8 is <= 20 % of adults
M.XBOW_SHARE = 30           -- % of the army in the crossbow squad (doctrine: 4-5 of 15)
M.FAST, M.SLOW = 600, 3600  -- upkeep cadence outside / in PEACE
M.UNSTICK = 33600           -- uniform-unstick --all --free (BUG-050: --drop only on an opt-in), at most monthly, PEACE only
M.ADD_PER_STEP = 5
M.KEEP_EXTRA = 2            -- remove soldiers only when a squad is this far above its target
M.KPI_TTL = 25
M.STATION_R = 3             -- a soldier within 3 tiles (same z) of the station is on station
M.SPREAD = 1                -- BUG-032: tiles around its station point DF stands a squad on (cfg stations.spread)
M.SPREAD_LIM = {0, 5}
M.RELOC_TTL = 6000          -- BUG-032: ticks a station's replacement is kept (revealed tiles change slowly)
M.NOTE_EVERY = 2400         -- BUG-032: a squad with no station clear of a bridge it holds is told at most this often
-- Run 11 siege 3 (y432/433: 25 dead, pop 54 -> 29, soldiers 10 -> 5, O1 destroyed): squads A and B emptied and were
-- never refilled, only C (5) remained. In SIEGE/BREACH (SIEGE_FILL) a melee squad below half its target is refilled
-- from healthy adult civilians who stand in Kern+ (the core), never from the refuge; the first melee squad's target is
-- at least HOLD_MIN then (the core stations need them; neither the shrunk population target nor the tools-first rule
-- lowers it in a siege). Tool-detail members only after everybody else (they keep their place in PEACE).
M.HOLD_MIN = 5              -- melee soldiers the core stations need in a siege (half a squad: the routine's minimum)
-- Run 11 (Kilrudrabed y441, siege 8: 10 soldiers at worn 58 %, no metal in ten years; the recruits without armor or a
-- weapon died first): melee positions are filled only as far as the gear goes (M.gear_fill). A melee set = a true body
-- armor, a melee weapon (metal melee weapons, then the axes beyond the woodcutters' keep; never a pick) and a shield,
-- free or carried by soldiers (economy's census: g_body, g_weapon, w_axe, g_shield). The melee squads are filled to
-- max(GEAR_FLOOR, sets) in plan order (the first squad keeps its leader and one: it trains and takes gear as it comes);
-- while economy says metal is short (economy.metal) the positions the gear cannot fill go to the crossbow squad (wooden
-- crossbows, wood/bone bolts: no metal), which economy equips (targets' 5th value) and military fills as far as the
-- crossbows beyond its own positions go (g_xbow). SIEGE/BREACH: the first melee squad is still refilled up to HOLD_MIN
-- from healthy core civilians beyond the gear (the core stations need bodies at the choke); the rest stays capped.
M.GEAR_FLOOR = 2
M.SIEGE_THIRST, M.SIEGE_HUNGER = 25000, 50000   -- healthy: below DF's thirsty / hungry marks, no wound, awake
M.RETRY, M.RETRY_MAX = 1200, 33600
M.NOTIFY_AFTER = 2          -- failed squad creations before DECISION_NEEDED (once per boot)
-- routine names (CONTRACTS §5 squad_routine resolves by name); first exact, then substring
M.ROUTINES = {train = {'constant training', 'constant'}, ready = {'ready', 'ready'}, off = {'off duty', 'off duty'}}
-- Gordon 11.10.2026: elite squads train nine months and are free for three; militia squads (citizens who keep
-- their jobs) train only those three months. Months are 0-based (28 days = 33600 ticks); the free months of
-- the elite are the training months of the militia, so somebody always trains. Only in the TRAIN posture
-- in PEACE; every alert posture overrides this.
-- FR-71 (Run 14 Trussroads: one window, one squad cannot give every citizen three months a year): M.MILITIA is a table
-- squad key -> the months that squad is on duty, so several militia squads rotate in windows of their own; the elite
-- is free in M.FREE_MONTHS, which defaults to the union of the windows when config/baseline.json "military" names
-- none (the old pair: militia B in 9-11, the elite free in 9-11). Both are read through M.conf (fairplay.MILITARY_LIM).
M.MILITIA = {B = {9, 10, 11}}                -- squad keys that are militia -> months on duty; the others are elite
M.FREE_MONTHS = {9, 10, 11}                  -- the elite's free months (nil: the union of the militia windows)
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
M.TOOL_LABORS = {'MINE', 'CUTWOOD', 'HUNT', 'FISH'}            -- live L5: economy staffs Fisherdwarves too
M.TOOL_DETAILS = {Miners = true, Woodcutters = true, Hunters = true, Fisherdwarves = true}
M.KEY_LABORS = {'MASON', 'CARPENTER', 'BREWER', 'PLANT', 'COOK', 'MECHANIC', 'DIAGNOSE', 'SMELT',
                'FORGE_WEAPON', 'FORGE_ARMOR'}
M.SQUAD_POSITIONS = {MILITIA_CAPTAIN = true, MILITIA_COMMANDER = true}   -- nobles that may still serve
M.TOOLS_MIN = 3
M.WEAPON_SKILLS = {'AXE', 'SWORD', 'MACE', 'HAMMER', 'SPEAR', 'PIKE', 'WHIP', 'DAGGER', 'CROSSBOW', 'BOW'}
M.CV_SKILLS = {'SHIELD', 'ARMOR', 'DODGING'}
M.METALS = {['INORGANIC:IRON'] = true, ['INORGANIC:STEEL'] = true}
local UNIFORM_CATS = {'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon'}
-- FR-46: item vectors of the gear categories (mil.free keys) and the loot unforbid budget per run
M.LOOT = {per_run = 40, every = 3600, cats = {{'WEAPON', 'weapon'}, {'ARMOR', 'body'}, {'HELM', 'head'}, {'PANTS', 'pants'},
                                {'GLOVES', 'gloves'}, {'SHOES', 'shoes'}, {'SHIELD', 'shield'}, {'AMMO', 'ammo'}}}
local WORN_ROLES = {'Worn', 'Weapon', 'Strapped'}

-- config/baseline.json "military" (dfpilot/fairplay.py MILITARY_LIM; a value of another type or out of range = the
-- default): unstick {on, drop, every, below, drop_after} (BUG-050), militia {key: [months]} and free_months [months]
-- (FR-71), early_pop (BUG-051), station_r (BUG-052). Module fields, not locals.
M.UNSTICK_DEF = {on = true, drop = false, every = M.UNSTICK, below = 100, drop_after = 2}
M.UNSTICK_LIM = {every = {1200, 403200}, below = {1, 100}, drop_after = {0, 12}}
M.EARLY_POP, M.EARLY_LIM = 40, {0, 250}
M.STATION_R_LIM = {1, 10}
-- FR-79 (note 67: the kernel rotates the citizens through the militia itself): rotation {on, per_day, worn_min}. on = false
-- keeps the members of a militia squad as before; per_day = the most members a turnover changes per game day (batches are at
-- least a day apart); worn_min = no turnover of members who wear kit while the army's worn % is below it (0 = never held).
M.ROT_DEF = {on = true, per_day = 3, worn_min = 40}
M.ROT_LIM = {per_day = {1, 10}, worn_min = {0, 100}}
M.ADD_TRIES = 3             -- BUG-076: refused candidates tried per refill before the squad backs off
M.ADD_BAD = 33600           -- BUG-076: a unit addToSquad refused is passed over this many ticks

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

-- {9, 10, 11} -> {[9] = true, ...}; nil unless a list of months 0-11
local function window_set(list)
  if type(list) ~= 'table' then return nil end
  local set = {}
  for k, m in pairs(list) do
    m = int(m)
    if not (int(k) and m and m >= 0 and m <= 11) then return nil end
    set[m] = true
  end
  return set
end

local function squad_key(k)
  for _, sp in ipairs(M.SQUADS) do if sp.key == k then return true end end
  return false
end

function M.conf(K)
  local b = type(K.cfg) == 'table' and type(K.cfg.baseline) == 'table' and K.cfg.baseline.military
  b = type(b) == 'table' and b or {}
  local c, u = {unstick = {}}, type(b.unstick) == 'table' and b.unstick or {}
  for k, def in pairs(M.UNSTICK_DEF) do
    local x = u[k]
    if type(def) == 'boolean' then
      if type(x) == 'boolean' then c.unstick[k] = x else c.unstick[k] = def end
    else
      local lim = M.UNSTICK_LIM[k]
      x = int(x)
      c.unstick[k] = (x and x >= lim[1] and x <= lim[2]) and x or def
    end
  end
  local mil
  if type(b.militia) == 'table' then             -- one bad entry and the whole table is the default
    mil = {}
    for k, list in pairs(b.militia) do
      local set = window_set(list)
      if type(k) == 'string' and squad_key(k) and set then mil[k] = set else mil = nil; break end
    end
  end
  local given = mil ~= nil
  if not mil then
    mil = {}
    for k, list in pairs(M.MILITIA) do mil[k] = window_set(list) end
  end
  local free = window_set(b.free_months)
  if not free then
    if given or not M.FREE_MONTHS then              -- named windows, no free months: the elite is free in their union
      free = {}
      for _, set in pairs(mil) do for m in pairs(set) do free[m] = true end end
    else
      free = window_set(M.FREE_MONTHS)
    end
  end
  c.militia, c.free = mil, free
  local ep = int(b.early_pop)
  c.early_pop = (ep and ep >= M.EARLY_LIM[1] and ep <= M.EARLY_LIM[2]) and ep or M.EARLY_POP
  local sr = int(b.station_r)
  c.station_r = (sr and sr >= M.STATION_R_LIM[1] and sr <= M.STATION_R_LIM[2]) and sr or M.STATION_R
  local rb = type(b.rotation) == 'table' and b.rotation or {}                 -- FR-79
  c.rot = {on = M.ROT_DEF.on}
  if type(rb.on) == 'boolean' then c.rot.on = rb.on end
  for k, lim in pairs(M.ROT_LIM) do
    local x = int(rb[k])
    c.rot[k] = (x and x >= lim[1] and x <= lim[2]) and x or M.ROT_DEF[k]
  end
  return c
end

local seat_leader   -- defined after the squad helpers
local SIEGE_FILL, hold_floor, siege_short   -- Run 11 siege 3, defined before M.step
local st      -- persisted m.military: {v, sq = {A = {id, uni, kind, auto}}, posture, pt, unstick}
local rt      -- runtime: retry ticks, applied orders, kpi cache, notified flags
local dirty

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

-- BUG-088: the census (sense) holds the fort's residents too, who are no citizens; the squads screen lists living adult
-- citizens only (BUG-085), so recruits and the militia cohort are citizens
local function citizen(u) return try(function() return dfhack.units.isCitizen(u) end) == true end

-- Run 11 siege 3: the manifest's Kern+ and refuge burrows (roles kern/refuge, refuge.burrow wins), as gate reads them
local function core_home(K)
  local man = K.manifest()
  local kern, refuge
  local names = {}
  for name in pairs(type(man.burrows) == 'table' and man.burrows or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  local function find(n) return n and try(function() return dfhack.burrows.findByName(n) end) or nil end
  return {kern = find(kern or 'Kern+'), refuge = find(refuge or 'Tiefe+'), kname = kern or 'Kern+'}
end

local function on_burrow(b, x, y, z)
  if not b or not x then return false end
  return try(function() return dfhack.burrows.isAssignedTile(b, {x = x, y = y, z = z}) end) == true
end

-- in the core: on a Kern+ tile and not on a refuge tile (a citizen in the refuge stays there)
local function core_where(home, u)
  local x, y, z = nil, nil, nil
  local ok, a, b, c = pcall(dfhack.units.getPosition, u)
  if ok then x, y, z = a, b, c end
  if on_burrow(home.refuge, x, y, z) then return 'refuge' end
  if on_burrow(home.kern, x, y, z) then return nil end
  return 'outside'
end

-- healthy enough to fight now: no wound, awake, not thirsty or hungry (fields a fake unit lacks read as fine)
local function healthy(u)
  local wounds = try(function() return #u.body.wounds end) or 0
  local out = try(function() return u.counters.unconscious end) or 0
  local th = try(function() return u.counters2.thirst_timer end) or 0
  local hu = try(function() return u.counters2.hunger_timer end) or 0
  return wounds == 0 and out <= 0 and th < M.SIEGE_THIRST and hu < M.SIEGE_HUNGER
end

-- candidates sorted best first: combat value, then strength + toughness, then id; plus exclusion counts.
-- siege (Run 11 siege 3, SIEGE/BREACH): only healthy adults standing in Kern+ and not in the refuge; members of the
-- tool details and holders of a tool labor come last instead of never (counted as tool all the same)
function M.recruits(K, siege)
  local cu = K.census.u
  local out, why = {}, {tool = 0, sole = 0, noble = 0, mood = 0, child = 0, squad = 0}
  if siege then why.outside, why.refuge, why.hurt = 0, 0, 0 end
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return out, why end
  local home = siege and core_home(K)
  if siege and not home.kern then why.no_core = 1; return out, why end   -- no Kern+: the core cannot be told
  local adults = {}
  for _, id in ipairs(cu.ids) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      if not dfhack.units.isAdult(u) then why.child = why.child + 1
      elseif citizen(u) then adults[#adults + 1] = u end
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
  local cand, cand2 = {}, {}
  for _, u in ipairs(adults) do
    local lab = labors(u)
    local tool_labor = false
    if lab then
      for _, l in ipairs(M.TOOL_LABORS) do if try(function() return lab[l] end) then tool_labor = true end end
    end
    local mood = try(function() return u.mood end)
    local where = siege and core_where(home, u)
    local function c() return {id = u.id, cv = M.cv(u), body = attr(u, 'STRENGTH') + attr(u, 'TOUGHNESS')} end
    if (try(function() return u.military.squad_id end) or -1) >= 0 then why.squad = why.squad + 1
    elseif where then why[where] = why[where] + 1
    elseif siege and not healthy(u) then why.hurt = why.hurt + 1
    elseif tools[u.id] or tool_labor then
      why.tool = why.tool + 1
      if siege and not sole[u.id] and not noble(u) and not (mood ~= nil and mood >= 0) then cand2[#cand2 + 1] = c() end
    elseif sole[u.id] then why.sole = why.sole + 1
    elseif noble(u) then why.noble = why.noble + 1
    elseif mood ~= nil and mood >= 0 then why.mood = why.mood + 1
    else
      cand[#cand + 1] = c()
    end
  end
  local function best(a, b)
    if a.cv ~= b.cv then return a.cv > b.cv end
    if a.body ~= b.body then return a.body > b.body end
    return a.id < b.id
  end
  table.sort(cand, best)
  table.sort(cand2, best)
  for _, c in ipairs(cand) do out[#out + 1] = c.id end
  for _, c in ipairs(cand2) do out[#out + 1] = c.id end
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

-- the phase the squads are staffed for: the current phase, or the plan's phase_target when the LLM's
-- approved plan aims higher (live L2: a fort behind its schedule, P2 in year 6, is staffed for the target)
local function phase_no(K)
  local ph = K.view().phase
  local n = type(ph) == 'string' and tonumber(ph:match('^P(%d)$')) or nil
  local tg = type(K.plan) == 'table' and K.plan.phase_target
  local t = type(tg) == 'string' and tonumber(tg:match('^P(%d)$')) or nil
  if n and t and t > n then return t end
  return n
end

-- BUG-051: is there a barracks? A fortcore station for the melee squads (stage 2 builds the gatehouse barracks with it),
-- a manifest room `barracks`, or a Barracks zone in the game (the player's, or a ruin's). Returns true/false and the
-- evidence ('station', 'room', 'zone', 'none'); nil when the zones cannot be read and the manifest says nothing (unknown
-- is no verdict). Cached for a day (the zone list is read, not scanned per tick).
function M.barracks(K)
  local now = now_tick(K)
  local c = rt.bk
  if c and now >= c.tick and now - c.tick < 1200 then return c.v, c.why end
  local man = K.manifest()
  local v, why
  if type(man.stations) == 'table' and man.stations.melee then v, why = true, 'station' end
  if not v then
    for _, rm in ipairs(type(man.rooms) == 'table' and man.rooms or {}) do
      if type(rm) == 'table' and rm.tpl == 'barracks' then v, why = true, 'room'; break end
    end
  end
  if not v then
    local ok, found = pcall(function()
      local ty = df.civzone_type and df.civzone_type.Barracks
      if ty == nil then error('no civzone_type.Barracks') end
      for _, z in ipairs(df.global.world.buildings.other.ANY_ZONE) do if z.type == ty then return true end end
      return false
    end)
    if ok then v, why = found, found and 'zone' or 'none' else v, why = nil, 'unread' end
  end
  rt.bk = {tick = now, v = v, why = why}
  return v, why
end

-- BUG-051 (Run 13 Wheelsblows: pop 47-59 for twenty years at P0 because a deliverable never finished: no squads, no
-- drill, worn 9-23 %): a fort of conf.early_pop (40) citizens with a barracks staffs its squads whatever phase the runner
-- reports. Latched in st.early so a fort near the threshold does not release its soldiers (and their kit) with every
-- death: it ends below half of early_pop citizens or without a barracks. early_pop 0 = off (the phase gates as before).
function M.early(K)
  local c = M.conf(K)
  if c.early_pop == 0 then
    if st.early then st.early, dirty = nil, true end
    return false
  end
  local cu = K.census.u
  local cit = type(cu) == 'table' and int(cu.cit) or nil
  if not cit then return st.early == 1 end
  local bk, why = M.barracks(K)
  if st.early == 1 then
    if bk == false or cit < c.early_pop // 2 then
      st.early, dirty = nil, true
      K.log('info', 'military: early squads end (%d citizens, barracks %s): the phase gates the squads again', cit, tostring(bk))
      return false
    end
    return true
  end
  if cit >= c.early_pop and bk == true then
    st.early, dirty = 1, true
    K.log('info', 'military: %d citizens and a barracks (%s) at phase %s: the squads are staffed before P2', cit, why,
          tostring(K.view().phase))
    return true
  end
  return false
end

-- wanted squad keys in order: phases P2-P4 only squad A, from P5 all (DESIGN §5.12); none before P2
local function active(K)
  local mil = type(K.plan) == 'table' and type(K.plan.military) == 'table' and K.plan.military or {}
  local sq = type(mil.squads) == 'table' and mil.squads or {}
  local melee = math.min(2, math.max(0, int(sq.melee) or 2))
  local xbow = math.min(1, math.max(0, int(sq.xbow) or 1))
  local ph = phase_no(K)
  if ph and ph < 2 and not M.early(K) then return {} end          -- BUG-051: a big fort with a barracks needs its squads
  local r = {}
  for _, s in ipairs(M.SQUADS) do
    if s.kind == 'melee' and melee > 0 then r[#r + 1] = s; melee = melee - 1
    elseif s.kind == 'xbow' and xbow > 0 then r[#r + 1] = s; xbow = xbow - 1 end
  end
  if ph and ph < 5 and #r > 1 then r = {r[1]} end
  return r
end

-- soldiers wanted in total and per squad key; third value: why the total is 0 on purpose ('tools': fewer than
-- TOOLS_MIN axes or picks, 'phase': a known phase before P2), else nil. Existing soldiers are released then. Fourth:
-- the tools-first rule took the melee squads. Fifth (Run 11): the gear cap, nil when the gear fills every melee
-- position (or the census does not know it): {sets, melee, want, xbow, fill = {key = n}, parts}: `per` stays the demand
-- (economy orders the gear for it), `fill` is what the squads are filled to, `xbow` the crossbow positions added to
-- the demand while metal is short
function M.targets(K)
  local cu = K.census.u
  local adults, cit = type(cu) == 'table' and cu.adults or 0, type(cu) == 'table' and cu.cit or 0
  local n = (adults * M.share(K, cit) + 99) // 100
  if adults >= M.R2_ADULTS then n = math.max(n, M.R2_MIN) end
  local act = active(K)
  local zero, short
  local ph = phase_no(K)
  if ph and ph < 2 and not M.early(K) then zero = 'phase' end
  -- live L6: the soldiers took the fort's only two (battle) axes for a year, so nobody cut wood and every
  -- build stalled. Tools first: no melee soldiers while the fort has fewer than TOOLS_MIN axes or picks in
  -- all. Live L7 (Paddletribes, no metal for years): crossbowmen carry no axe or pick, so the crossbow
  -- squad stays staffed (the fort had 14 crossbows and 1100 bolts and no soldiers at all)
  local ci = K.census.i
  if type(ci) == 'table' and ((ci.w_axe or 0) < M.TOOLS_MIN or (ci.w_pick or 0) < M.TOOLS_MIN) then
    local only = {}
    for _, s in ipairs(act) do if s.kind == 'xbow' then only[#only + 1] = s end end
    act = only
    if #act == 0 then n, zero = 0, zero or 'tools' end
    short = true
  end
  n = math.min(n, M.SIZE * #act)
  local per = {}
  local melee, xbow = {}, nil
  for _, s in ipairs(act) do per[s.key] = 0; if s.kind == 'melee' then melee[#melee + 1] = s.key else xbow = s.key end end
  if #act == 0 then return 0, per, zero, short end
  if n == 0 then return 0, per, zero, short end
  local nx = 0
  if xbow then                                    -- live L2: every wanted squad gets at least its leader
    if #melee == 0 then nx = n
    elseif n >= #act then nx = math.max(n >= 4 and 2 or 1, (n * M.XBOW_SHARE + 50) // 100) end
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
  return n, per, nil, short, M.gear_fill(K, per, act)
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
  -- BUG-055: the act's refusal and the verbs that do it (Run 11 note 25: "appoint a militia commander/captain" with no
  -- word on why the kernel could not, nor on how to do it without replaying act.lua by hand)
  -- J3: d.q is at most 200 bytes (schema.py, a longer one broke the contract): the squads first, then the act's refusal, the
  -- fix whole at the end (the verbs take their arguments from RULES section 6)
  local fix = '; fix: dfllm cmd squad.create/squad.leader/appoint, inspect offices'
  local why = rt.create_why and ('; refused: ' .. rt.create_why:sub(1, 40)) or ''
  local head = table.concat(parts, '; ')
  if #head > 200 - #fix - #why then head = head:sub(1, 200 - #fix - #why - 3) .. '...' end
  local q = head .. why .. fix
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
  -- live L6: right after adopt the runner has not published a phase yet; a squad made then drafted the miners'
  -- and woodcutters' tools before the phase gate (P2) and the tools-first rule could say no. Adopting a squad
  -- that exists is fine; creating one waits for a known phase.
  if phase_no(K) == nil then return nil end
  if waiting_for_leader() or not retry_ok(K, 'create' .. k) or #recruits() == 0 then return nil end
  local leader = table.remove(recruits(), 1)
  local ok, id = K.act.squad_create(k, {assignment_id = free_assignment(), leader = leader, kind = spec.kind})
  s = ok and squad(id)
  if not s then
    rt.create_why = ok and 'the new squad was not found' or tostring(id)          -- BUG-055: named in the DECISION
    rt.create_since = rt.create_since or now_tick(K)
    backoff(K, 'create' .. k)
    stuck(K)
    return nil
  end
  cleared('create' .. k)
  rt.create_why, rt.create_since = nil, nil
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

-- material per uniform category, "best available" (live L2: the fort held no armor at all, so metal-only
-- specs would stay empty and worn would read 0): metal when the fort has enough free metal items of that
-- type for the squad's target, else leather when enough leather ones, else any material. Free = not
-- forbidden, owned, in a building, with a trader or held by someone outside the military.
local CAT_ITEMS = {body = 'ARMOR', head = 'HELM', pants = 'PANTS', gloves = 'GLOVES', shoes = 'SHOES', shield = 'SHIELD'}
local function free_item(it)
  local f = it.flags
  if f.forbid or f.owned or f.in_building or f.trader or f.garbage_collect or f.removed or f.melt or f.dump then return false end
  if f.in_inventory then
    local u = dfhack.items.getHolderUnit(it)
    if u and (u.military.squad_id or -1) < 0 then return false end
  end
  return true
end
function M.stock_mats(cat)
  local n = {metal = 0, leather = 0, any = 0}
  try(function()
    for _, it in ipairs(df.global.world.items.other[CAT_ITEMS[cat]]) do
      if free_item(it) then
        n.any = n.any + 1
        local mi = dfhack.matinfo.decode(it)
        local fl = mi and mi.material and mi.material.flags
        if fl and fl.IS_METAL then n.metal = n.metal + 1 elseif fl and fl.LEATHER then n.leather = n.leather + 1 end
      end
    end
  end)
  return n
end
local function best_mats(need)
  local r = {}
  for cat in pairs(CAT_ITEMS) do
    local n = M.stock_mats(cat)
    local per = (cat == 'gloves' or cat == 'shoes') and 2 or 1      -- worn in pairs
    r[cat] = (n.metal >= need * per and 'metal') or (n.leather >= need * per and 'leather') or 'any'
  end
  return r
end
local function with_mats(spec, mats)
  local c = {}
  for key, v in pairs(spec) do c[key] = v end
  c.items = {}
  for _, it in ipairs(spec.items) do
    if not (spec.no_weapon and it.cat == 'weapon') then
      local x = {}
      for key, v in pairs(it) do x[key] = v end
      x.mat = mats[it.cat] or 'any'
      c.items[#c.items + 1] = x
    end
  end
  c.no_weapon = nil
  return c
end

---------------------------------------------------------------- weapons: the civilians' tools stay (live L6)
-- Laborkings: 'individual choice, melee' handed the fort's only battle axes and picks to the soldiers (a battle
-- axe is the woodcutter's tool, a pick the miner's). While the soldiers wanted could drain them (fewer than
-- AXE_KEEP + melee soldiers axes or PICK_KEEP + melee soldiers picks in the fort, census.i w_axe/w_pick), melee
-- positions get explicit weapon subtypes instead: other melee weapons in stock first, then only the axes and picks
-- beyond AXE_KEEP and PICK_KEEP; a position left without one gets none until the stock grows.
M.AXE_KEEP, M.PICK_KEEP = 1, 2

-- {k = 'pick'|'axe'|'ranged'|'melee', token} of a weapon subtype (economy's weapon_kind: by the raws' skills)
local function weapon_kind(sub)
  sub = int(sub)
  if not sub or sub < 0 then return nil end
  local c = rt.wk[sub]
  if c == nil then
    c = false
    local d = try(function() return dfhack.items.getSubtypeDef(df.item_type.WEAPON, sub) end)
    if d then
      local js, k = df.job_skill, 'melee'
      if (int(d.skill_ranged) or -1) >= 0 then k = 'ranged'
      elseif tostring(d.id):find('_TRAINING$') then k = 'melee'        -- FR-89: a wooden training weapon is no work tool
      elseif d.skill_melee == js.MINING then k = 'pick'
      elseif d.skill_melee == js.AXE then k = 'axe' end
      c = {k = k, token = d.id}
    end
    rt.wk[sub] = c
  end
  return c or nil
end

M.weapon_kind = weapon_kind                  -- (module field: tests read it; no new local)

-- weapon spec subtypes of a position (-1 = individual choice)
local function weapon_specs(p)
  local r = {}
  try(function()
    for _, sp in ipairs(p.equipment.uniform.weapon) do r[#r + 1] = int(sp.item_subtype) or -1 end
  end)
  return r
end

-- BUG-023 (Run 10): the tools the builtin tool details need stay with them: one pick per Miners member, one axe
-- per Woodcutters member, at least economy's demand before its tool cap (economy caps the members by the free
-- unreserved tools, so counting members alone let the soldiers' reservations shrink the details), AXE_KEEP /
-- PICK_KEEP as the floor. Read-only.
local function tool_keep(K)
  local keep = {pick = M.PICK_KEEP, axe = M.AXE_KEEP}
  local ok, want = false, nil
  if K and K.call then ok, want = K.call('economy', 'tool_want') end
  if ok and type(want) == 'table' then
    keep.pick = math.max(keep.pick, int(want.pick) or 0)
    keep.axe = math.max(keep.axe, int(want.axe) or 0)
  end
  try(function()
    for _, wd in ipairs(df.global.plotinfo.labor_info.work_details) do
      local name, n = dfhack.df2utf(wd.name), #wd.assigned_units
      if name == 'Miners' then keep.pick = math.max(keep.pick, n)
      elseif name == 'Woodcutters' then keep.axe = math.max(keep.axe, n) end
    end
  end)
  return keep
end

-- nil while the melee soldiers wanted cannot drain the tools, else the axes and picks soldiers may hold
local function weapon_guard(K, per)
  local ci = K.census.i
  if type(ci) ~= 'table' then return nil end
  local melee = 0
  for _, sp in ipairs(M.SQUADS) do if sp.kind == 'melee' then melee = melee + (per[sp.key] or 0) end end
  if melee == 0 then return nil end
  local axes, picks = int(ci.w_axe) or 0, int(ci.w_pick) or 0
  local keep = tool_keep(K)
  if axes - keep.axe >= melee and picks - keep.pick >= melee then return nil end
  return {axe = math.max(0, axes - keep.axe), pick = math.max(0, picks - keep.pick), keep = keep}
end
M.weapon_guard = weapon_guard

-- Run 11: melee sets in the fort (true body armor, melee weapons incl. the spare axes, shields; free or carried by
-- soldiers), nil while economy's census does not count them; second value the parts
function M.gear_sets(K)
  local ci = K.census.i
  if type(ci) ~= 'table' then return nil end
  local body, wpn, shield = int(ci.g_body), int(ci.g_weapon), int(ci.g_shield)
  if not (body and wpn and shield) then return nil end
  local axes = math.max(0, (int(ci.w_axe) or 0) - tool_keep(K).axe)
  return math.min(body, wpn + axes, shield), {body = body, weapon = wpn + axes, shield = shield}
end

-- Run 11: the gear cap of M.targets (see M.GEAR_FLOOR): nil when the sets fill every melee position wanted
function M.gear_fill(K, per, act)
  local sets, parts = M.gear_sets(K)
  if not sets then return nil end
  local melee, xk, want = {}, nil, 0
  for _, s in ipairs(act) do
    if s.kind == 'melee' then melee[#melee + 1] = s.key; want = want + (per[s.key] or 0) else xk = s.key end
  end
  local fill, avail, got = {}, math.max(sets, M.GEAR_FLOOR), 0
  for k, v in pairs(per) do fill[k] = v end
  for _, k in ipairs(melee) do
    local f = math.min(per[k] or 0, avail)
    fill[k], avail, got = f, avail - f, got + f
  end
  if got >= want then return nil end
  local g = {sets = sets, melee = got, want = want, xbow = 0, fill = fill, parts = parts}
  local okm, mt = K.call('economy', 'metal')
  if xk and okm and type(mt) == 'table' and mt.short then
    local base = per[xk] or 0
    local extra = math.min(want - got, M.SIZE - base)
    if extra > 0 then
      local ci = K.census.i
      g.xbow, fill[xk] = extra, base + math.min(extra, math.max(0, (int(ci.g_xbow) or 0) - base))
    end
  end
  return g
end

-- BUG-023 (Run 10: "3 free picks, 3 reserved by squad uniforms" while 2 of 6 miners held none): an explicit pick or
-- axe weapon spec makes DF reserve a free tool for the position (v1 E18: reserved tools are never handed out as
-- work tools). While guarded, the specs of a tool kind beyond the spare tools are given up: {pick = n, axe = n}.
local function tool_excess(g)
  if not g then return nil end
  local claim = {pick = 0, axe = 0}
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    if s then
      try(function()
        for _, p in ipairs(s.positions) do
          for _, sub in ipairs(weapon_specs(p)) do
            local w = weapon_kind(sub)
            if w and claim[w.k] then claim[w.k] = claim[w.k] + 1 end
          end
        end
      end)
    end
  end
  local ex = {pick = claim.pick, axe = math.max(0, claim.axe - g.axe)}   -- no pick spec at all (v1 E18)
  return (ex.pick > 0 or ex.axe > 0) and ex or nil
end

-- BUG-023 (Run 10: 6 of 9 picks stayed in items_assigned after their specs were given up, the miners got none): a pick
-- or axe nobody carries that DF keeps reserved for a fort squad position without a weapon spec of that kind (explicit,
-- or individual choice while the tools are safe) is unassigned (act.squad_release, the squads screen's unassign).
local function release_tools(K)
  local ok, ids = pcall(function()
    local refs = {}
    local gid = df.global.plotinfo.group_id
    for _, s in ipairs(df.global.world.squads.all) do
      if s.entity_id == gid then
        for _, p in ipairs(s.positions) do
          local r = {kinds = {}, choice = false}
          for _, sub in ipairs(weapon_specs(p)) do
            local w = weapon_kind(sub)
            if w then r.kinds[w.k] = true elseif sub < 0 then r.choice = true end
          end
          local function mark(id) refs[id] = refs[id] or {}; local l = refs[id]; l[#l + 1] = r end
          for _, id in ipairs(p.equipment.assigned_items) do mark(id) end
          for _, wsp in ipairs(p.equipment.uniform.weapon) do for _, id in ipairs(wsp.assigned) do mark(id) end end
        end
      end
    end
    local out = {}
    for _, id in ipairs(df.global.plotinfo.equipment.items_assigned.WEAPON) do
      local it = df.item.find(id)
      local w = it and weapon_kind(it:getSubtype())
      if w and (w.k == 'pick' or w.k == 'axe') and not dfhack.items.getHolderUnit(it) then
        local keep = false
        for _, r in ipairs(refs[id] or {}) do if r.kinds[w.k] or (r.choice and rt.wguard == nil) then keep = true end end
        if not keep then out[#out + 1] = id end
      end
    end
    return out
  end)
  if not ok or type(ids) ~= 'table' or #ids == 0 then return end
  local okr, n = K.act.squad_release(ids)
  if okr then
    K.log('info', 'military: %d of %d reserved picks/axes nobody carries unassigned (no weapon spec of that kind; '
          .. 'the miners and woodcutters need them)', int(n) or 0, #ids)
  end
end

local function holds_kind(u, k)              -- the soldier carries a weapon of that kind (a pick, an axe)
  return try(function()
    for _, e in ipairs(u.inventory) do
      local it = e.item
      if it and it:getType() == df.item_type.WEAPON then
        local w = weapon_kind(it:getSubtype())
        if w and w.k == k then return true end
      end
    end
    return false
  end) == true
end

-- up to n weapon tokens for bare melee positions: free melee weapons that are no tools (minus the explicit specs
-- that already claim them), then the spare axes, then the spare picks
local function weapon_plan(g, n)
  local stock, tool_tok = {}, {}
  try(function()
    for _, it in ipairs(df.global.world.items.other.WEAPON) do
      local w = free_item(it) and weapon_kind(it:getSubtype())
      if w then
        if w.k == 'melee' then
          if not tostring(w.token):find('_TRAINING$') then stock[w.token] = (stock[w.token] or 0) + 1 end   -- review: no wooden spare
        elseif w.k == 'axe' or w.k == 'pick' then tool_tok[w.k] = tool_tok[w.k] or w.token end
      end
    end
  end)
  local tools = {axe = g.axe, pick = g.pick}
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    if s then
      try(function()
        for _, p in ipairs(s.positions) do
          for _, sub in ipairs(weapon_specs(p)) do
            local w = weapon_kind(sub)
            if w and w.k == 'melee' and stock[w.token] then stock[w.token] = stock[w.token] - 1
            elseif w and tools[w.k] then tools[w.k] = tools[w.k] - 1; tool_tok[w.k] = tool_tok[w.k] or w.token end
          end
        end
      end)
    end
  end
  local toks = {}
  for t in pairs(stock) do toks[#toks + 1] = t end
  table.sort(toks)
  local r = {}
  for _ = 1, n do
    local best
    for _, t in ipairs(toks) do if stock[t] > 0 and (best == nil or stock[t] > stock[best]) then best = t end end
    if best then stock[best] = stock[best] - 1
    elseif tools.axe > 0 and tool_tok.axe then best, tools.axe = tool_tok.axe, tools.axe - 1
    else break end                     -- BUG-023 (v1 E18): never a pick spec, it reserves the miners' picks
    r[#r + 1] = best
  end
  return r
end

-- e.nw: positions dfllm left without a weapon spec while guarded (persisted; a UI uniform without a weapon is
-- never touched while the tools are safe)
local function nw_set(e, pos, on)
  local r, has = {}, false
  for _, p in ipairs(e.nw or {}) do
    if p == pos then has = true; if on then r[#r + 1] = p end else r[#r + 1] = p end
  end
  if on and not has then r[#r + 1] = pos; table.sort(r) end
  if has ~= (on == true) then e.nw, dirty = #r > 0 and r or nil, true end
end
local function nw_has(e, pos)
  for _, p in ipairs(e.nw or {}) do if p == pos then return true end end
  return false
end

-- FR-89 (Run 14 note 82, Gordon 26.10.: "drills only with wooden weapons, build enough"): the vanilla training raws by
-- weapon class (df.job_skill name). Hammer, mace, pick, whip, dagger, pike and the ranged classes have none (vanilla)
M.TRAINING = {AXE = 'ITEM_WEAPON_AXE_TRAINING', SWORD = 'ITEM_WEAPON_SWORD_SHORT_TRAINING',
              SPEAR = 'ITEM_WEAPON_SPEAR_TRAINING'}

-- the weapon class of a squad member's position: 'TRAINING' (a training weapon is the spec already), the skill of the
-- weapon the position's spec names (df.job_skill name), else his best weapon skill (the class an individual choice
-- would take), nil without any
function M.weapon_class(m)
  for _, sub in ipairs(weapon_specs(m.p)) do
    if sub >= 0 then
      local d = try(function() return dfhack.items.getSubtypeDef(df.item_type.WEAPON, sub) end)
      if d then
        if tostring(d.id):find('_TRAINING$') then return 'TRAINING' end
        local sk = int(d.skill_melee)
        if sk and sk >= 0 and df.job_skill[sk] then return df.job_skill[sk] end
      end
    end
  end
  local top, name = 0, nil
  for _, sk in ipairs(M.WEAPON_SKILLS) do
    local lv = try(function() return dfhack.units.getNominalSkill(m.unit, df.job_skill[sk]) end)
    if type(lv) == 'number' and lv > top then top, name = lv, sk end
  end
  return name
end

-- the squads screen's weapon slot of the positions `only` (a set of 0-based positions, nil = all) to the training weapon
-- of their class, one act call per weapon (the same act as every uniform kind); positions with a class that has no training
-- raw stay as they are. Returns set = positions changed, held = positions that carried a training weapon already, left =
-- {{pos, cls}} unchanged, counts = {AXE = n, ...}, fail = the act's refusal
function M.train_apply(K, s, only)
  local by, order, held, left, counts, set, fail = {}, {}, 0, {}, {}, {}, nil
  for _, m in ipairs(members(s)) do
    if not only or only[m.pos] then
      local cls = M.weapon_class(m)
      local tok = cls and M.TRAINING[cls]
      if cls == 'TRAINING' then held = held + 1
      elseif tok then
        if not by[tok] then by[tok] = {}; order[#order + 1] = tok end
        table.insert(by[tok], m.pos)
        counts[cls] = (counts[cls] or 0) + 1
      else left[#left + 1] = {pos = m.pos, cls = cls or 'none'} end
    end
  end
  for _, tok in ipairs(order) do
    local ok, res = K.act.squad_uniform(s.id, {mode = 'replace', positions = by[tok],
                                               items = {{cat = 'weapon', type = 'WEAPON', subtype = tok, mat = 'any'}}})
    if ok then
      for _, p in ipairs(by[tok]) do set[#set + 1] = p end
    else
      fail = tostring(res)
    end
  end
  table.sort(set)
  return {set = set, held = held, left = left, counts = counts, fail = fail}
end

-- melee positions get a weapon spec: while guarded every occupied position without one or with an individual-choice
-- spec gets an explicit subtype (weapon_plan); while the tools are safe the positions dfllm left without one get
-- individual choice again
local function ensure_weapons(K, k, s)
  local e = st.sq[k]
  if not e or e.kind == 'xbow' or not retry_ok(K, 'wpn' .. k) then return end
  local g = rt.wguard
  -- FR-89: a squad on the training policy gives every occupied position the training weapon of its class (a vacant position
  -- keeps the kit's individual-choice spec, so a recruit's metal weapon is changed here); the classes without one go on below
  -- review: the policy is a PEACE/DRILL one. In any other mode (ALERT, SIEGE, BREACH, RECOVERY) the positions that carry a
  -- training weapon get individual choice (or a planned real weapon while guarded) back below, and the wooden ones are put on
  -- again once PEACE returns: a squad never meets an army with wooden weapons
  local mode = K.mode()
  local trn = e.tr == 1 and (mode == 'PEACE' or mode == 'DRILL')
  if trn then
    local tr = M.train_apply(K, s, nil)
    for _, p in ipairs(tr.set) do nw_set(e, p, false) end
    if #tr.set > 0 then
      K.log('info', 'military: squad %s: %d positions changed to the training weapon of their class', k, #tr.set)
    end
    if tr.fail then                                   -- the act refused (e.g. a world without the training raws): not every upkeep
      backoff(K, 'wpn' .. k)
      if not rt.no_train then rt.no_train = {} end
      if rt.no_train[k] ~= tr.fail then
        rt.no_train[k] = tr.fail
        K.log('warn', 'military: squad %s: training weapons refused: %s', k, tr.fail)
      end
    end
  end
  local need, marked = {}, {}
  for _, m in ipairs(members(s)) do
    local ws = weapon_specs(m.p)
    local bad = #ws == 0 and (g ~= nil or nw_has(e, m.pos))
    if g and not bad then for _, sub in ipairs(ws) do if sub < 0 then bad = true end end end
    if e.tr == 1 and not trn and not bad and M.weapon_class(m) == 'TRAINING' then bad = true end     -- review: see above
    if bad then need[#need + 1] = m.pos; marked[m.pos] = true end
  end
  -- BUG-023: tool specs beyond the spare tools are re-planned, the soldiers without that tool in hand first
  local ex, given = g and rt.wexcess, 0
  if ex then
    for pass = 1, 2 do
      for _, m in ipairs(members(s)) do
        for _, sub in ipairs(weapon_specs(m.p)) do
          local w = weapon_kind(sub)
          if w and (ex[w.k] or 0) > 0 and not marked[m.pos] and (pass == 2) == holds_kind(m.unit, w.k) then
            need[#need + 1], marked[m.pos], ex[w.k], given = m.pos, true, ex[w.k] - 1, given + 1
          end
        end
      end
    end
  end
  if given > 0 then
    K.log('info', 'military: squad %s: %d positions give up their pick/axe spec (the Miners/Woodcutters need the tools; '
          .. 'a reserved tool is never handed out as a work tool)', k, given)
  end
  if #need == 0 then cleared('wpn' .. k); return end
  table.sort(need)
  if not g then
    if K.act.squad_uniform(s.id, {mode = 'replace', positions = need,
                                  items = {{cat = 'weapon', type = 'WEAPON', choice = 'melee', mat = 'any'}}}) then
      for _, p in ipairs(need) do nw_set(e, p, false) end
    end
    backoff(K, 'wpn' .. k)
    return
  end
  local plan = weapon_plan(g, #need)
  local by, order = {}, {}
  for i, tok in ipairs(plan) do
    if not by[tok] then by[tok] = {}; order[#order + 1] = tok end
    table.insert(by[tok], need[i])
  end
  for _, tok in ipairs(order) do
    if K.act.squad_uniform(s.id, {mode = 'replace', positions = by[tok],
                                  items = {{cat = 'weapon', type = 'WEAPON', subtype = tok, mat = 'any'}}}) then
      for _, p in ipairs(by[tok]) do nw_set(e, p, false) end
    end
  end
  if #plan < #need then
    local left = {}
    for i = #plan + 1, #need do left[#left + 1] = need[i]; nw_set(e, need[i], true) end
    K.act.squad_unequip(s.id, left, {'weapon'})       -- an individual-choice spec would take the tools
  end
  if #plan < #need and not rt.no_wpn[k] then
    rt.no_wpn[k] = true
    K.log('warn', 'military: squad %s: %d positions without a weapon (no spare weapon; %d axes and %d picks stay '
          .. 'with the civilians)', k, #need - #plan, (g.keep or {}).axe or M.AXE_KEEP, (g.keep or {}).pick or M.PICK_KEEP)
  end
  backoff(K, 'wpn' .. k)
end

-- every occupied position needs uniform specs (checked each upkeep). The first uniform goes to the
-- whole squad; later only to the bare positions (spec.positions, 0-based), so a uniform chosen in the
-- UI is kept. e.uni = 1 while no occupied position is bare.
local function ensure_uniform(K, k, s, want)
  local e = st.sq[k]
  local bare, any = bare_positions(s)
  local uni = #bare == 0 and 1 or 0
  if uni == 1 then cleared('uni' .. k)
  elseif retry_ok(K, 'uni' .. k) then
    rt.mats[k] = rt.mats[k] or best_mats(math.max(1, want or 1))
    local base = M.UNIFORM[e.kind] or M.UNIFORM.melee
    local guarded = rt.wguard ~= nil and e.kind ~= 'xbow'
    local trn = e.tr == 1 and e.kind ~= 'xbow'        -- FR-89: the training policy: ensure_weapons picks the weapons too
    guarded = guarded or trn
    if guarded then                                   -- ensure_weapons picks the weapons (live L6)
      local b = {}
      for key, v in pairs(base) do b[key] = v end
      b.no_weapon, base = true, b
    end
    local spec = with_mats(base, rt.mats[k])
    if any then spec.positions = bare end
    if K.act.squad_uniform(s.id, spec) then
      uni = 1
      if guarded then
        for _, m in ipairs(members(s)) do
          if not any or nw_has({nw = bare}, m.pos) then nw_set(e, m.pos, true) end
        end
      end
    end
    backoff(K, 'uni' .. k)                            -- re-checked next upkeep either way
  end
  if e.uni ~= uni then e.uni, dirty = uni, true end
end

-- the squads screen's "choose leader" for a squad without one (act.squad_leader [S2, live L2]): the best
-- recruit takes the squad's commander/captain assignment and position 0. A refusal backs off and names
-- the UI action once (stuck).
function seat_leader(K, k, s, recruits)
  if not retry_ok(K, 'lead' .. k) then return end
  -- live L2: the commander was carried to bed after a ghost's beating, DF vacated his position, and the
  -- squad kept two soldiers but no leader (no recruit left). A member is promoted first: the squads
  -- screen lets you choose a member as the new leader (here: off the roster, then into position 0).
  local best
  for _, m in ipairs(members(s)) do
    if m.pos ~= 0 and (best == nil or M.cv(m.unit) > M.cv(best.unit)) then best = m end
  end
  local uid, from_squad = best and best.unit.id, best ~= nil
  if not uid then uid = recruits()[1] end
  if not uid then stuck(K); return end
  local ok, err
  if from_squad then
    ok, err = K.act.squad_remove(s.id, uid)
    if ok then ok, err = K.act.squad_leader(s.id, uid) end
  else
    ok, err = K.act.squad_leader(s.id, uid)
  end
  if ok and leader_set(s) then
    if not from_squad then table.remove(recruits(), 1) end
    cleared('lead' .. k)
    K.log('info', 'military: squad %s (id %d) led by unit %d%s', k, s.id, uid, from_squad and ' (promoted)' or '')
    return
  end
  K.log('warn', 'military: squad %s: leader %d not seated: %s', k, uid, tostring(err))
  backoff(K, 'lead' .. k)
  stuck(K)
end

-- siege (Run 11 siege 3): in SIEGE/BREACH only a squad below half its target is refilled, from M.recruits(K, true).
-- BUG-076 (found beside FR-79): a refused addToSquad backed the squad off and nothing ever cleared that backoff, so every
-- later refusal waited twice as long (1,200 .. 33,600 ticks) for good; and the refused unit stayed the first candidate,
-- so one unit DF would not take blocked the refill of the whole squad. Now a success clears the backoff, a refused unit
-- is passed over for ADD_BAD ticks and the next candidate is tried (ADD_TRIES refusals per refill), and the refusal's
-- text goes to kern.log (at most every NOTE_EVERY ticks per squad). rot (FR-79): the candidates come in the rotation's
-- order and the member over the target who leaves is the most served one, not the weakest fighter.
local function fill(K, k, s, want, recruits, siege, rot)
  local mem = members(s)
  local n = #mem
  local low = not siege or n < (want + 1) // 2
  local now = now_tick(K)
  if n < want and low and retry_ok(K, 'add' .. k) and leader_set(s) then
    local added, ids, fails = 0, {}, 0
    for uid, t in pairs(rt.add_bad) do if t <= now then rt.add_bad[uid] = nil end end
    while n < want and added < M.ADD_PER_STEP and #recruits() > 0 do
      local uid = table.remove(recruits(), 1)
      if (rt.add_bad[uid] or 0) <= now then
        local ok, err = K.act.squad_add(s.id, uid)
        if ok then
          n, added, ids[#ids + 1] = n + 1, added + 1, uid
          cleared('add' .. k)
        else
          fails = fails + 1
          rt.add_bad[uid] = now + M.ADD_BAD
          local last = rt.add_note[k]
          if last == nil or now < last or now - last >= M.NOTE_EVERY then
            rt.add_note[k] = now
            K.log('warn', 'military: squad %s: unit %d was not taken in (%s); passed over for %d ticks', k, uid,
                  tostring(err), M.ADD_BAD)
          end
          if fails >= M.ADD_TRIES then break end
        end
      end
    end
    if fails > 0 and (added == 0 or fails >= M.ADD_TRIES) then backoff(K, 'add' .. k) end
    if siege and added > 0 then
      rt.kpi = nil
      K.log('warn', 'military: %s refill: squad %s %d -> %d of %d with healthy civilians from the core: %s',
            K.mode(), k, n - added, n, want, table.concat(ids, ','))
    end
  elseif n > want + M.KEEP_EXTRA and K.mode() == 'PEACE' then
    local worst                                  -- lowest combat value (rotation: the most served), never the leader
    for _, m in ipairs(mem) do
      if m.pos ~= 0 then
        if worst == nil then worst = m
        elseif rot then
          local a, b = st.served[m.unit.id] or 0, st.served[worst.unit.id] or 0
          if a > b or (a == b and m.unit.id > worst.unit.id) then worst = m end
        elseif M.cv(m.unit) < M.cv(worst.unit) then worst = m end
      end
    end
    if worst then K.act.squad_remove(s.id, worst.unit.id) end
  end
end

---------------------------------------------------------------- FR-79: the militia rotation
-- Gordon 2026-10-23 (note 67, goal Z12 "every adult citizen who is not elite serves three months a year in the
-- militia"): the kernel moves the citizens through the militia squads itself. Before, nothing but fill() changed WHO sat
-- in squad B: it topped the squad up with the best fighters and let them stay (fill adds when n < want and removes only
-- when n > want + KEEP_EXTRA), M.windows only logged the windows and off_season only switched the routine, so the same
-- pool served window after window; a hand-made cohort lost the race against fill's top-up in PEACE (the SIEGE_FILL
-- rules of the note only act in SIEGE/BREACH). Rules (the pure parts are in dfllm.rotation):
--   * squads: the keys of the militia table (config military.militia); the elite squads (A, C by default) never take part;
--     the squad's leader (the militia captain, an appointed office) stays, the members rotate; cohort size = the squad's
--     target `want` (army share D-12, gear cap) minus the leader
--   * eligible: adults who are in no squad, no noble, in no mood, no patient or wounded, with no tool labor (the Miners,
--     Woodcutters, Hunters and Fisherdwarves keep their picks and axes), and not the only civilian holder of a key labor;
--     ranked by the militia windows served (persisted `served`), then by unit id: everybody serves once before anybody twice
--   * edge: a window CLOSES at its last month; then the members are credited with the window they served, and the next cohort
--     takes the squad: members who are in it stay (their kit stays), the others leave in swaps with the entrants (squad_remove,
--     squad_add: the squads screen), the most served first; the cohort sits in the squad through the months off duty and
--     is equipped when the window opens. A turnover that could not run before the window reopens lapses (the same members
--     serve again; `ms`), the first sight of a squad only records the last close (no turnover at once).
--   * bounds: PEACE only and no lockdown, no hostile in sight (military.danger), at most `per_day` members a game day (one
--     batch a day), and not while the army's worn % is below `worn_min` when a leaver wears kit; the kernel never drops,
--     unequips or moves an item (a leaver's kit is DF's equipment pass; a new member's position keeps the squad's
--     uniform specs, bare positions get them from ensure_uniform at once). In SIEGE/BREACH the existing fill rules hold.
-- Observability: state mil.rot, kern.log, MILITIA_ROTATED (B).
function M.rot_on(K, key)
  local c = M.conf(K)
  return c.rot.on and c.militia[key] ~= nil
end

M.ROT_LABORS = {'MASON', 'CARPENTER', 'BREWER', 'PLANT', 'COOK', 'MECHANIC', 'DIAGNOSE', 'SMELT', 'FORGE_WEAPON',
                'FORGE_ARMOR', 'MILLER', 'SURGERY', 'BONE_SETTING'}

local function patient(u)
  return try(function()
    if u.health and u.health.flags.needs_healthcare then return true end
    return #u.body.wounds > 0
  end) == true
end

local function abs_month()
  return ROT.abs_month(try(function() return df.global.cur_year end), try(function() return df.global.cur_year_tick end))
end

-- the citizens who may sit in squad s: {{id, held = key labors}}, civilians per key labor, and why the others may not
function M.rot_pool(K, s)
  local cu = K.census.u
  local why = {squad = 0, child = 0, tool = 0, noble = 0, mood = 0, hurt = 0, refused = 0}
  local now = now_tick(K)
  local adults = {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then
      if not dfhack.units.isAdult(u) then why.child = why.child + 1
      elseif citizen(u) then adults[#adults + 1] = u end
    end
  end
  local lead = try(function() return s.positions[0].occupant end) or -1
  local tools, civ, cand = tool_members(), {}, {}
  for _, u in ipairs(adults) do
    local sid = try(function() return u.military.squad_id end) or -1
    local mine = sid == s.id
    local boss = mine and lead >= 0 and u.hist_figure_id == lead
    local lab = labors(u)
    local held, tool_labor = {}, false
    if lab then
      for _, l in ipairs(M.ROT_LABORS) do if try(function() return lab[l] end) then held[#held + 1] = l end end
      for _, l in ipairs(M.TOOL_LABORS) do if try(function() return lab[l] end) then tool_labor = true end end
    end
    if (sid < 0 or mine) and not boss then
      for _, l in ipairs(held) do civ[l] = (civ[l] or 0) + 1 end    -- who would be a civilian
    end
    local mood = try(function() return u.mood end)
    if boss then -- the leader stays
    elseif sid >= 0 and not mine then why.squad = why.squad + 1
    elseif tools[u.id] or tool_labor then why.tool = why.tool + 1
    elseif noble(u) then why.noble = why.noble + 1
    elseif mood ~= nil and mood >= 0 then why.mood = why.mood + 1
    elseif patient(u) then why.hurt = why.hurt + 1
    elseif (rt.add_bad[u.id] or 0) > now then why.refused = why.refused + 1     -- BUG-076: DF would not take him in
    else cand[#cand + 1] = {id = u.id, held = held} end
  end
  return cand, civ, why
end

-- the next cohort of squad s: {picks = ids (rank order, at most size), order = every eligible id in rank order, eligible,
-- lo, hi (served counts of the eligible), why}; the sole civilian holder of a key labor is passed over
function M.rot_cohort(K, s, size)
  local cand, civ, why = M.rot_pool(K, s)
  local by, ids = {}, {}
  for _, c in ipairs(cand) do by[c.id] = c; ids[#ids + 1] = c.id end
  local ranked = ROT.rank(ids, st.served)
  local order, refused = ROT.pick(ranked, #ranked, function(id)
    local held = by[id].held
    for _, l in ipairs(held) do if (civ[l] or 0) <= 1 then return false end end
    for _, l in ipairs(held) do civ[l] = civ[l] - 1 end
    return true
  end)
  why.sole = #refused
  local picks = {}
  for i = 1, math.min(size, #order) do picks[i] = order[i] end
  local lo, hi = ROT.spread(ranked, st.served)
  return {picks = picks, order = order, eligible = #ids - #refused, lo = lo, hi = hi, why = why}
end

-- fill()'s candidates for a rotation squad: the eligible in rank order, the cohort first (nobody who is a member already);
-- the ones after the cohort are the next in line when DF refuses a unit (BUG-076)
function M.rot_source(K, s, want)
  local list
  return function()
    if not list then
      list = {}
      local have = {}
      for _, m in ipairs(members(s)) do have[m.unit.id] = true end
      for _, id in ipairs(M.rot_cohort(K, s, math.max(0, want - 1)).order) do
        if not have[id] then list[#list + 1] = id end
      end
    end
    return list
  end
end

-- soldiers who are fetching their kit (a PickupEquipment job)
local function fetching()
  local pk = df.job_type and df.job_type.PickupEquipment
  local n = 0
  if pk == nil then return 0 end
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    for _, m in ipairs(s and members(s) or {}) do
      if try(function() return m.unit.job.current_job.job_type end) == pk then n = n + 1 end
    end
  end
  return n
end

-- kern.log once per squad and reason (and edge): a turnover that waits, a cohort that stays; a reason that flips back and
-- forth (a hostile coming and going) is logged at most every NOTE_EVERY ticks, the state shows the current one
local function rot_note(K, k, sig, fmt, ...)
  if rt.rot_why[k] == sig then return end
  local now = now_tick(K)
  local last = rt.rot_t[k]
  if last and now >= last and now - last < M.NOTE_EVERY then return end
  rt.rot_why[k], rt.rot_t[k] = sig, now
  K.log('info', fmt, ...)
end

-- the turnover of squad s at the close of a window: one batch of swaps. Returns true when members changed.
local function rot_turn(K, sp, s, want, r, ed, info, c, now)
  local k = sp.key
  local function hold(why, ...)
    info.why = 'held: ' .. string.format(why, ...)
    rt.rot_last[k] = info.why:sub(7)
    -- BUG-089: the reason is the signature, not its numbers ('worn 38% < 40%' moves with every upkeep): once per close
    rot_note(K, k, ed.close .. info.why:gsub('%d+', '#'), 'military: militia squad %s: the turnover at the close of month '
             .. '%d waits (%s)', k, ed.close % 12, info.why:sub(7))
    return false
  end
  if want < 2 then                                                -- a squad of the leader alone: nothing to rotate
    r.e, r.lw, r.me, dirty = ed.close, 'no seats beside the leader', nil, true
    return false
  end
  local danger = M.danger(K)
  if danger then return hold('%s', danger) end
  if not leader_set(s) then return hold('no leader') end
  if r.t and now >= r.t and now - r.t < 1200 then
    info.why = 'next batch tomorrow'
    return false
  end
  local mem, ids, by = members(s), {}, {}
  for _, m in ipairs(mem) do
    if m.pos ~= 0 then ids[#ids + 1] = m.unit.id; by[m.unit.id] = m end
  end
  local co = M.rot_cohort(K, s, want - 1)
  info.e, info.lo, info.hi = co.eligible, co.lo, co.hi
  local out, into = ROT.plan(ids, co.picks, st.served)
  local few = co.eligible < want - 1 and (r.me or 0) == 0           -- fewer eligible than seats: the cohort cannot be formed
  if few or #out == 0 or #into == 0 then                          -- nothing (more) to swap: the turnover is over
    r.e, dirty = ed.close, true
    if (r.me or 0) > 0 then
      r.n, r.lw = r.n + 1, 'rotated'
    else
      r.lw = few and string.format('fewer eligible than seats: %d for %d', co.eligible, want - 1)
             or string.format('same cohort: %d eligible for %d seats', co.eligible, want - 1)
      rot_note(K, k, 'end' .. ed.close, 'military: militia squad %s: no turnover at the close of month %d: %s', k,
               ed.close % 12, r.lw)
    end
    r.me = nil
    return false
  end
  local n = math.min(c.rot.per_day, #out, #into)
  local worn = M.kpi(K).worn
  if worn < c.rot.worn_min then
    for i = 1, n do
      local m = by[out[i]]
      local _, filled = uniform_counts(m.p, m.unit, st.sq[k].kind)
      if filled > 0 then return hold('worn %d%% < %d%%', worn, c.rot.worn_min) end
    end
  end
  local moved = 0
  for i = 1, n do
    local okr, errr = K.act.squad_remove(s.id, out[i])
    local oka, erra = false, nil
    if okr then oka, erra = K.act.squad_add(s.id, into[i]) end
    if not (okr and oka) then
      rot_note(K, k, 'fail' .. ed.close .. i, 'military: militia squad %s: swap of %d for %d failed (%s)', k, out[i],
               into[i], tostring(okr and erra or errr))
      if okr then rt.add_bad[into[i]] = now + M.ADD_BAD end     -- BUG-076: the next batch takes another
      break
    end
    moved = moved + 1
  end
  r.t, r.me, dirty = now, (r.me or 0) + moved, true
  if moved == 0 then info.why = 'swap refused'; return false end
  r.mv = r.mv + moved
  local left = math.min(#out, #into) - moved
  if left <= 0 then r.e, r.n, r.me, r.lw = ed.close, r.n + 1, nil, 'rotated' end
  rt.rot_look = {t = now, w = worn, key = k, n = moved, i = 1}
  info.why = left > 0 and string.format('%d more to swap', left) or nil
  local txt = string.format('militia squad %s rotated: %d out, %d in (window %s closed; %d eligible, served %d..%d)', k,
                            moved, moved, info.w or '?', co.eligible, co.lo, co.hi)
  K.log('info', 'military: %s; worn %d%%%s', txt, worn, left > 0 and string.format('; %d swaps follow', left) or '')
  K.emit('MILITIA_ROTATED', 'B', txt:sub(1, 200), {squad = k, out = moved, into = moved, size = want, eligible = co.eligible,
         lo = co.lo, hi = co.hi, win = info.w, left = left, worn = worn, edge = ed.close % 12})
  return true
end

-- one militia squad in the upkeep: credit the window that closed, run the turnover while it is due, publish rt.rot[k].
-- Returns true when members changed (the caller refreshes the uniforms).
function M.rot_step(K, sp, s, want, now)
  local k = sp.key
  local c = M.conf(K)
  local win = c.militia[k]
  if not (c.rot.on and win) then rt.rot[k] = nil; return false end
  local info = {w = ROT.months_text(win), z = want}
  rt.rot[k] = info
  local a = abs_month()
  local ed = ROT.edges(win, a)
  if not ed then info.why = 'no window edge'; return false end
  info.on = ed.open and 1 or 0
  local r = st.rot[k]
  if r and (r.c > a or r.e > a) then r = nil end                  -- the clock went back (an older save): start over
  if not r then
    r = {c = ed.close, e = ed.close, n = 0, mv = 0, ms = 0}
    st.rot[k], dirty = r, true
    K.log('info', 'military: militia squad %s: rotation on (window months %s, last close month %d): the first turnover is at '
          .. 'the next close', k, info.w, ed.close % 12)
  end
  local mem = members(s)
  info.n = #mem
  if r.c < ed.close then                                          -- the window that closed: its members served it
    local live = {}
    for _, id in ipairs(type(K.census.u) == 'table' and K.census.u.ids or {}) do live[id] = true end
    for _, m in ipairs(mem) do st.served[m.unit.id] = (st.served[m.unit.id] or 0) + 1 end
    if next(live) then for id in pairs(st.served) do if not live[id] then st.served[id] = nil end end end
    r.c, r.me, dirty = ed.close, 0, true
  end
  local changed = false
  if r.e < ed.close then
    if ed.open then                                               -- the window reopened first: the same members serve again
      local why = rt.rot_last[k]
      r.e, r.ms, r.me, dirty = ed.close, r.ms + 1, nil, true
      r.lw = 'lapsed' .. (why and (': ' .. why) or '')
      K.log('warn', 'military: militia squad %s: the turnover at the close of month %d did not run before the window '
            .. 'reopened%s: the same members serve again', k, ed.close % 12, why and (' (' .. why .. ')') or '')
    else
      changed = rot_turn(K, sp, s, want, r, ed, info, c, now)
    end
  end
  if info.e == nil then                                           -- the numbers of the state (a scan at most every 3,600 ticks)
    local cc = rt.rot_cc and rt.rot_cc[k]
    if not cc or now < cc.t or now - cc.t >= M.SLOW then
      local co = M.rot_cohort(K, s, math.max(0, want - 1))
      cc = {t = now, e = co.eligible, lo = co.lo, hi = co.hi}
      rt.rot_cc = rt.rot_cc or {}
      rt.rot_cc[k] = cc
    end
    info.e, info.lo, info.hi = cc.e, cc.lo, cc.hi
  end
  info.rt, info.mv = r.n, r.mv
  local to = r.e < ed.close and 0 or ed.next_close
  info.nx = ROT.days_to(to, try(function() return df.global.cur_year_tick end))
  if not info.why and r.lw and r.e == ed.close then info.why = 'last: ' .. r.lw end
  if info.why then info.why = info.why:sub(1, 60) end
  if changed then info.n = #members(s) end
  return changed
end

-- what the militia squads of this kernel look like after the member sets changed: the follow-up lines of a turnover
-- (worn % and soldiers fetching kit a day and a week later: the equipment cost of squad_remove/squad_add, live data)
function M.rot_look(K, now)
  local l = rt.rot_look
  if not l or not M.US_LOOK[l.i] or now < l.t then return end
  if now - l.t >= M.US_LOOK[l.i] then
    K.log('info', 'military: militia turnover %d ticks ago (squad %s, %d swapped): worn %d%% before, %d%% now, %d soldiers '
          .. 'fetching kit', now - l.t, l.key, l.n, l.w, rt.kpi and rt.kpi.worn or 0, fetching())
    l.i = l.i + 1
  end
end

-- a militia squad that cannot rotate because it does not exist or its target is 0: the state says so (no squad B)
local function rot_idle(K, key, why)
  local c = M.conf(K)
  local win = c.militia[key]
  rt.rot[key] = (c.rot.on and win) and {w = ROT.months_text(win), why = why} or nil
end

-- the unit ids of the shared recruit list that sit in a squad now (a rotation squad took them from its own list)
local function drop_seated(list)
  for i = #list, 1, -1 do
    local u = df.unit.find(list[i])
    if not u or (try(function() return u.military.squad_id end) or -1) >= 0 then table.remove(list, i) end
  end
end

-- live L6 (Laborkings: no own axes, the soldiers held the only battle axes and picks): when the targets drop to 0
-- on purpose (tools first, a phase before P2) every soldier leaves, after the squad's uniform specs and assigned
-- items are released (act.squad_unequip, the squads screen's equip > remove), so the tools go back to the
-- civilians. PEACE only; the leader (position 0) leaves last.
local function release(K, why, kind)
  local n = 0
  for _, sp in ipairs(M.SQUADS) do
    local e = (kind == nil or sp.kind == kind) and st.sq[sp.key]
    local s = e and squad(e.id)
    local mem = s and members(s) or {}
    if #mem > 0 then
      K.act.squad_unequip(s.id)
      table.sort(mem, function(a, b) return a.pos > b.pos end)
      for _, m in ipairs(mem) do if K.act.squad_remove(s.id, m.unit.id) then n = n + 1 end end
      if e.uni ~= 0 or e.nw then e.uni, e.nw, dirty = 0, nil, true end
      rt.mats[sp.key], rt.order[sp.key] = nil, nil
    end
  end
  if n > 0 then
    rt.kpi = nil
    K.log('warn', 'military: %d soldiers released (%s): uniforms cleared, the tools go back to the civilians', n, why)
  end
  return n
end

---------------------------------------------------------------- postures and orders
-- BUG-029: is a manifest core bridge (B2) not down? (gate.state 'up' or 'moving'; unknown = not built, not up)
local function core_up(K, man)
  for name, b in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    if type(b) == 'table' and b.role == 'core' then
      local ok, s = K.call('gate', 'state', name)
      if ok and (s == 'up' or s == 'moving') then return true end
    end
  end
  return false
end

-- BUG-029: the inner station, on the side of the fort that holds the drink: stations.melee (inside B1) while every
-- core bridge is down, else stations.b2 (behind the core seal). BUG-032: a chain (see station_of)
local ALT_CORE, ALT_Z4 = {name = 'core', alt = true}, {name = 'z4', alt = true}
local function inner_chain(K, man, stations)
  if stations.b2 and core_up(K, man) then return {'b2', ALT_CORE, ALT_Z4, 'melee'} end
  return {'melee', 'b2', ALT_CORE, ALT_Z4}
end

-- the killing field station of a wave: stations.field, else the centre of the first killbox
local function field_station(man, stations)
  if stations.field then return stations.field end
  local kb = type(man.killboxes) == 'table' and man.killboxes[1]
  if type(kb) == 'table' and type(kb.bbox) == 'table' and #kb.bbox == 6 then
    local c = geom.bbox_center(kb.bbox)
    return {c.x, c.y, c.z}
  end
end

-- the routine and the station chain of a posture (nil: no station). BUG-032: an entry is a manifest station name,
-- 'field' (field_station), 'z4' (the centre of the biggest Z4 box: the core level; the nearest revealed floor to it)
-- or {name, pos, alt}; alt entries are tried only after an earlier one could not be made clear of the bridges, so a
-- manifest without them keeps the stations it had (BUG-029/030 order: b2 or melee, core or b2 or melee, ...)
local function station_of(K, man, P, kind, first_melee, stations)
  if P == 'STATION_B1' then return 'train', first_melee and inner_chain(K, man, stations) or nil end
  if P == 'READY_STATION' then
    if kind == 'xbow' then return 'ready', {'gallery', 'melee', {name = 'b2', alt = true}, ALT_CORE, ALT_Z4} end
    return 'ready', {'melee', {name = 'b2', alt = true}, ALT_CORE, ALT_Z4}
  end
  if P == 'B2_HOLD' then return 'ready', {'b2', ALT_CORE, ALT_Z4, 'melee'} end
  if P == 'READY_IN' then return 'ready', inner_chain(K, man, stations) end
  if P == 'CORE' then return 'ready', {'core', 'b2', ALT_Z4, 'melee'} end            -- BUG-030
  if P == 'INTAKE' then return 'ready', kind == 'xbow' and {'gallery', 'field'} or {'field'} end
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

local function pstr(p) return p and string.format('%d,%d,%d', p.x, p.y, p.z) or '?' end

---------------------------------------------------------------- BUG-032: stations clear of the bridges
-- config/reflex.json stations.spread: the tiles around its station point DF stands a squad's soldiers on
local function spread(K)
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.stations) == 'table' and K.cfg.reflex.stations or {}
  local s = int(r.spread)
  if not s or s < M.SPREAD_LIM[1] or s > M.SPREAD_LIM[2] then s = M.SPREAD end
  return s
end

-- the clearance (a station lies farther than this from every footprint on its level) and gate's margin
local function clearance(K)
  local ok, m = K.call('gate', 'margin')
  m = ok and int(m) or 1
  return m + spread(K), m
end

-- snapshot.tile (revealed tiles only: nil for a hidden one, fair play), nil without the module
local function tile_reader(K)
  return function(x, y, z)
    local ok, t = K.call('snapshot', 'tile', x, y, z)
    return ok and type(t) == 'table' and t or nil
  end
end

-- a chain entry -> name, position, seek (find the nearest floor to it even when no bridge holds it)
local function resolve(man, stations, ent)
  local name = type(ent) == 'table' and ent.name or ent
  if type(ent) == 'table' and ent.pos then return name, posp(ent.pos), ent.seek end
  if name == 'field' then return name, posp(field_station(man, stations)) end
  if name == 'z4' then return name, SL.z4_centre(man), true end
  return name, posp(stations[name])
end

-- the nearest revealed floor to p clear of the bridges (cached per manifest, position and clearance for RELOC_TTL)
local function reloc(K, man, brs, p, blk, clear, o)
  local now = now_tick(K)
  if rt.reloc_man ~= man then rt.reloc, rt.reloc_man = {}, man end
  local key = string.format('%s|%d|%s', pstr(p), clear, o.tag or '')
  local c = rt.reloc[key]
  if c and now >= c.t and now - c.t < M.RELOC_TTL then return c.q or nil end
  local q = SL.relocate(man, brs, p, blk, {clear = clear, need_by = o.need_by, side = o.side, ring = clear,
                                           tile = tile_reader(K)})
  q = q and geom.pos(q.x, q.y, q.z) or nil
  rt.reloc[key] = {t = now, q = q or false}
  return q
end

-- the station of a chain: the first entry that lies clear of every bridge footprint (o.need_by: a stricter clearance
-- for a bridge; o.side: an inner side it must lie on), else moved to the nearest revealed floor on the inner side of
-- the footprints that hold it, else the next entry (alt entries only after one failed; o.all: every entry).
-- Returns {pos, name, from (the entry's own position when it moved), first = {name, pos}, blk = the first holder}
local function pick(K, man, stations, chain, o)
  o = o or {}
  local clear = clearance(K)
  local brs = SL.bridges(man)
  local r, failed = {}, o.all == true
  for _, ent in ipairs(chain) do
    local alt = type(ent) == 'table' and ent.alt
    if failed or not alt then
      local name, p, seek = resolve(man, stations, ent)
      if p then
        if not r.first then r.first = {name = name, pos = p} end
        local blk = SL.blockers(brs, p, clear, o.need_by)
        local inside = not o.side or o.side(p.x, p.y, p.z)
        if #blk == 0 and inside and not seek then r.pos, r.name = p, name; return r end
        local q = reloc(K, man, brs, p, blk, clear, o)
        if q then r.pos, r.name, r.from = q, name, (not seek) and p or nil; r.blk = r.blk or blk[1]; return r end
        r.blk = r.blk or blk[1] or (not inside and {name = o.bridge or '?', d = -1}) or nil
        failed = true
      end
    end
  end
  return r
end

local function blk_txt(b, clear, margin)
  if not b then return '' end
  if b.d and b.d < 0 then return string.format(' on the outer side of %s', b.name) end
  local need = b.need or clear
  return string.format(' %d tile%s from bridge %s (clearance %d: gate margin %d + spread %d)', b.d,
                       b.d == 1 and '' or 's', b.name, need, margin, need - margin)
end

-- STATION_MOVED (B) and a kern.log line once per station and outcome (per boot): moved (why bridge), another station of
-- the chain (chain), none clear (none: the first stays)
local function note_pick(K, r)
  local f = r.first
  if not f or (r.name == f.name and not r.from) then return end
  local to = r.pos
  local key = f.name .. '@' .. pstr(f.pos)
  local sig = to and (r.name .. '@' .. pstr(to)) or 'none'
  rt.noted = rt.noted or {}
  if rt.noted[key] == sig then return end
  rt.noted[key] = sig
  local clear, margin = clearance(K)
  local b = r.blk
  local why, txt
  if to and r.name == f.name then
    why = 'bridge'
    txt = string.format('station %s %s lies%s: moved to %s (the nearest revealed floor on its inner side)', f.name,
                        pstr(f.pos), blk_txt(b, clear, margin), pstr(to))
  elseif to then
    why = 'chain'
    txt = string.format('station %s %s lies%s, no revealed floor clear of it on its inner side within %d tiles: %s %s '
                        .. 'instead', f.name, pstr(f.pos), blk_txt(b, clear, margin), SL.SEARCH_R, r.name, pstr(to))
  else
    why = 'none'
    txt = string.format('station %s %s lies%s and no station of its chain is clear of the bridges: kept (its soldiers '
                        .. 'hold that bridge)', f.name, pstr(f.pos), blk_txt(b, clear, margin))
  end
  local d = {why = why, station = r.name or f.name, first = f.name, from = geom.arr(f.pos)}
  if to then d.to = geom.arr(to) end
  if b then d.bridge, d.d = b.name, b.d end
  K.emit('STATION_MOVED', 'B', txt:sub(1, 200), d)
  K.log(why == 'bridge' and 'info' or 'warn', 'military: %s', txt)
end

-- the station of posture P for squad kind `kind` (first melee): pos or nil, and the chain's first entry
local function posture_station(K, man, stations, P, kind, first_melee)
  local which, chain = station_of(K, man, P, kind, first_melee, stations)
  if not chain then return which, nil, nil end
  local r = pick(K, man, stations, chain)
  note_pick(K, r)
  local src = r.first and (r.first.name .. '@' .. pstr(r.first.pos)) or nil
  return which, r.pos or (r.first and r.first.pos), src
end

-- is this squad off duty right now? FR-71: a militia squad (M.conf militia) is on duty only in its own window, an
-- elite squad is free in the free months (see M.MILITIA, M.FREE_MONTHS)
local function off_season(K, k)
  if st.posture ~= 'TRAIN' or K.mode() ~= 'PEACE' then return false end
  local month = (try(function() return df.global.cur_year_tick end) or 0) // 33600
  local c = M.conf(K)
  local win = c.militia[k]
  if win then return win[month] ~= true end    -- militia: on duty only in its own window
  return c.free[month] == true
end

-- bring one squad to the posture; force = re-issue even if it looks applied. Returns ok.
local function apply_squad(K, k, force)
  local e = st.sq[k]
  local s = e and squad(e.id)
  if not s then return true end
  if rt.held[k] then return true end                 -- siege holds this squad's sortie order (hold_order)
  local so = rt.so[k]
  if so and so.keep then return true end             -- M3 (BUG-113): a sortie against a lone harmless intruder is kept until sortie_pass ends it
  local man = K.manifest()
  local stations = type(man.stations) == 'table' and man.stations or {}
  local which, pos, src = posture_station(K, man, stations, st.posture, e.kind, k == first_melee_key())
  local ov = rt.over[k]                               -- BUG-032: re-stationed off a bridge it held (restation)
  if ov then
    if ov.P == st.posture and ov.src == src then pos = ov.pos else rt.over[k] = nil end
  end
  local off = not pos and off_season(K, k)
  if off then which = 'off' end
  local ok = true
  local idx, name = resolve_routine(which)
  if not idx and M.ROUTINE_FALLBACK[which] then idx, name = resolve_routine(M.ROUTINE_FALLBACK[which]) end
  if not idx then
    if not rt.warned_routine then rt.warned_routine = true; K.log('warn', 'military: no routine named %s', which) end
    ok = false
  elseif force or routine_idx(s) ~= idx then
    ok = K.act.squad_routine(s.id, name) and ok
  end
  local sig = pos and string.format('station:%d,%d,%d', pos.x, pos.y, pos.z) or (off and 'off' or 'train')
  local cur = rt.order[k]
  local held = cur and (cur:sub(1, 5) == 'kill:' or cur:sub(1, 7) == 'sortie:') and order_count(s) > 0
  if held and not force then return ok end           -- a kill order or an approved sortie runs
  local drift = (pos and order_count(s) == 0) or (not pos and order_count(s) > 0)
  if force or cur ~= sig or drift then
    local r = K.act.squad_order(s.id, pos and {kind = 'station', pos = pos} or {kind = off and 'clear' or 'train'})
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
-- opts.melee (intake waves, Gordon 2026-10-16): the melee squads stand in the killing field (posture INTAKE) and get
-- the order too. A squad siege holds for a sortie (hold_order) never gets one.
function M.kill(K, ids, opts)
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
  local sq, kind = {}, 'xbow'
  if type(opts) == 'table' and opts.melee == true then kind = nil end      -- every squad
  for _, q in ipairs(squads_of(kind)) do
    if not rt.held[q.key] then sq[#sq + 1] = q end
  end
  if #sq == 0 then return false, 0 end
  local sig = 'kill:' .. table.concat(t, ',')
  local n = 0
  for _, q in ipairs(sq) do
    if K.act.squad_order(q.s.id, {kind = 'kill', units = t}) then rt.order[q.key], n = sig, n + 1 end
  end
  rt.kpi = nil
  return n > 0, #t
end

-- public (BUG-065, reflex's intruder_sortie offer): the squad a sortie would send, key and member count: the melee squad
-- with the most soldiers (A first on a tie), else the crossbow squad; squads a sortie of siege holds are left out; nil
-- when no squad has a member
function M.sortie_squad(K)
  local best, bk, bn = nil, nil, 0
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    local n = s and #members(s) or 0
    if n > 0 and not rt.held[sp.key] then
      local rank = (sp.kind == 'melee' and 1000 or 0) + n
      if not best or rank > best then best, bk, bn = rank, sp.key, n end
    end
  end
  return bk, bn
end

---------------------------------------------------------------- M3 (BUG-113): the sortie to a position, tracked
-- Run 14 y707 note 96: `squad.sortie` with a position set a station order only ("move to"); the soldiers walked there, the
-- order was consumed on arrival, the next upkeep (military.lua step, drift) gave the BREACH posture back, nothing said
-- whether they arrived, and the kernel never killed the one goblin. Now (config/reflex.json `sortie`, read through
-- siege.so_conf): a position with a visible hostile within `kill_near` tiles sets a KILL order on it (a station order
-- otherwise, and a kill order as soon as the squad has arrived and one stands there); the sortie is tracked in rt.so
-- (SORTIE events, class B: phase go / arrived / dead / abort with why); a sortie against a lone harmless intruder is kept
-- against the posture (rt.so[k].keep, apply_squad) while the squad is worn >= `worn` percent; soldiers who stand beside
-- the target `idle_ticks` without an attack (DF does not treat it as an enemy) end it as `not_attackable` and the
-- reflex clears the unit; a target on another walk group is refused with the groups named. `no killbox` falls back to a
-- kill order on the one hostile in sight. military.kill_lone is the kernel's own order (reflex, BREACH).
M.SO_DEF = {worn = 80, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800}
M.SO_EVERY = 100           -- ticks between two looks at a running position sortie
M.SO_ARRIVE, M.SO_ADJ = 3, 2   -- tiles: a member this close to the target has arrived / stands beside the unit
M.SO_REISSUE = 3           -- a kill order DF dropped while the target lives is given again this often

local function so_conf(K)
  local ok, c = K.call('siege', 'so_conf')
  local r = {}
  for k, v in pairs(M.SO_DEF) do r[k] = (ok and type(c) == 'table' and int(c[k])) or v end
  return r
end

local function so_event(K, key, phase, txt, d)
  d = d or {}
  d.phase, d.squad = phase, key
  K.emit('SORTIE', 'B', txt:sub(1, 200), d)
  K.log('info', 'military: sortie %s %s: %s', tostring(key), phase, txt:sub(1, 160))
end

local function unit_dead(id)
  local u = try(function() return df.unit.find(id) end)
  if not u then return true end
  return try(function() return dfhack.units.isDead(u) or not dfhack.units.isActive(u) end) == true
end

local function unit_xyz(id)
  local u = try(function() return df.unit.find(id) end)
  if not u then return nil end
  local ok, x, y, z = pcall(dfhack.units.getPosition, u)
  return ok and x and {x = x, y = y, z = z} or nil
end

local function cheb(a, b) return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y), math.abs(a.z - b.z)) end

-- the visible hostiles of the census within r tiles of p, nearest first
local function hostiles_near(K, p, r)
  local h = K.census.h
  local out = {}
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do
    local d = cheb(e, p)
    if d <= r then out[#out + 1] = {id = e.id, d = d, e = e} end
  end
  table.sort(out, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  return out
end

-- why the squad cannot walk to p: the walk groups differ (a raised bridge, a wall), or nil (same group / unknown). Asked
-- through snapshot.groups (revealed tiles only; 0, hidden and unknown give no verdict)
local function unreachable(K, s, p)
  local pts = {{x = p.x, y = p.y, z = p.z}}
  for _, m in ipairs(members(s)) do
    local mp = try(function() return {x = m.unit.pos.x, y = m.unit.pos.y, z = m.unit.pos.z} end)
    if mp then pts[#pts + 1] = mp end
  end
  local ok, g = K.call('snapshot', 'groups', pts, true)
  if not (ok and type(g) == 'table') then return nil end
  local gt = int(g[1])
  if not gt or gt <= 0 then return nil end
  local gs
  for i = 2, #pts do
    local x = int(g[i])
    if x and x > 0 then
      if x == gt then return nil end                       -- one member can walk there
      gs = gs or x
    end
  end
  if not gs then return nil end
  return string.format('target unreachable: %s is on walk group %d, the squad on %d (a raised bridge, a wall or a closed door between)',
                       pstr(p), gt, gs)
end

local function so_ids_txt(ids)
  local l = {}
  for i = 1, math.min(#ids, 3) do l[i] = tostring(ids[i]) end
  return table.concat(l, ',') .. (#ids > 3 and ('+' .. (#ids - 3)) or '')
end

-- begin a tracked sortie of squad `key` with `order` (station or kill); meta: cmd, by, keep
local function so_begin(K, key, s, order, meta)
  local ok, err = K.act.squad_order(s.id, order)
  if not ok then return false, 'order failed: ' .. tostring(err) end
  local now = now_tick(K)
  rt.order[key] = 'sortie:' .. tostring(meta.cmd or '?')
  rt.kpi = nil
  local old = rt.so[key]
  rt.so[key] = {cmd = tostring(meta.cmd or '?'), by = meta.by or 'verb', t0 = old and old.t0 or now, last = now, kind = order.kind,
                ids = order.units, tgt = order.pos or (old and old.tgt), keep = meta.keep == true, adj = 0, re = 0,
                arrived = old and old.arrived or false, unseen = 0, mode = K.mode(), w0 = nil}
  if order.kind == 'kill' then
    rt.so[key].tgt = rt.so[key].tgt or unit_xyz(order.units[1])
  end
  if M.every.ticks > M.SO_EVERY then M.every = {ticks = M.SO_EVERY} end
  return true
end

local function so_end(K, key, phase, why, txt, d)
  local so = rt.so[key]
  rt.so[key] = nil
  rt.order[key] = nil
  rt.kpi = nil
  d = d or {}
  d.why = why
  if so and so.ids then d.units = so.ids end
  if so and so.tgt then d.pos = {so.tgt.x, so.tgt.y, so.tgt.z} end
  if so then d.ticks = now_tick(K) - so.t0 end
  so_event(K, key, phase, txt, d)
  apply_squad(K, key, true)
end

local function sum_wounds(id)
  local u = try(function() return df.unit.find(id) end)
  if not u then return nil end
  return try(function() return #u.body.wounds end)
end

-- one look at every running position sortie (military's step, every SO_EVERY ticks while one runs)
local function sortie_pass(K, now)
  if next(rt.so) == nil then return false end
  local c = so_conf(K)
  local mode = K.mode()
  for _, sp in ipairs(M.SQUADS) do
    local key = sp.key
    local so = rt.so[key]
    if so then
      local e = st.sq[key]
      local s = e and squad(e.id)
      local dt = math.max(1, now - (so.last or now))
      so.last = now
      local info = s and M.squad_info(K, key)
      local lone, lwhy
      if so.keep then lone, lwhy = M.lone_of(K, so.ids) end
      if rt.held[key] then
        rt.so[key] = nil
      elseif not s or not info or info.n == 0 then
        so_end(K, key, 'abort', 'no_squad', 'sortie ' .. key .. ' ended: the squad has no members')
      elseif mode == 'PEACE' then
        so_end(K, key, 'abort', 'mode', 'sortie ' .. key .. ' ended: the mode is PEACE')
      elseif now - so.t0 >= c.hold_ticks then
        so_end(K, key, 'abort', 'timeout', string.format('sortie %s ended after %d ticks: %s', key, now - so.t0,
               so.arrived and 'arrived, the target is still there' or 'the squad has not arrived'))
      elseif so.keep and info.worn < c.worn then
        so_end(K, key, 'abort', 'worn', string.format('sortie %s ended: worn %d%% < %d%%', key, info.worn, c.worn))
      elseif so.keep and not lone and (lwhy == 'group' or lwhy == 'dangerous' or (lwhy ~= 'none' and (so.nolone or 0) + dt >= M.SO_EVERY * 2)) then
        so_end(K, key, 'abort', 'more_hostiles', 'sortie ' .. key .. ' ended: the picture is no lone harmless intruder any more')
      else
        so.nolone = (so.keep and not lone and lwhy ~= 'none') and (so.nolone or 0) + dt or nil     -- (reflex's census scan may lag one pass)
        -- members near the target
        local tp = so.tgt
        if so.kind == 'kill' then
          local alive, seen = {}, {}
          for _, id in ipairs(so.ids) do
            if not unit_dead(id) then alive[#alive + 1] = id end
          end
          if #alive == 0 then
            so_end(K, key, 'dead', 'killed', string.format('sortie %s: target %s dead after %d ticks', key, so_ids_txt(so.ids),
                   now - so.t0))
            goto continue
          end
          local cur
          for _, h in ipairs(type(K.census.h) == 'table' and K.census.h.list or {}) do
            for _, id in ipairs(alive) do if h.id == id then cur = cur or h; seen[id] = true end end
          end
          so.ids = alive
          -- fair play: the target's position is read from the census (units in sight) only; out of sight the last known
          -- position stays and the unseen clock runs
          if cur then tp, so.tgt, so.unseen = {x = cur.x, y = cur.y, z = cur.z}, {x = cur.x, y = cur.y, z = cur.z}, 0
          else so.unseen = so.unseen + dt end
          if so.unseen >= c.idle_ticks then
            so_end(K, key, 'abort', 'gone', string.format('sortie %s ended: target %s out of sight for %d ticks', key, so_ids_txt(so.ids), so.unseen))
            goto continue
          end
        end
        local near_n, adj_n = 0, 0
        for _, m in ipairs(members(s)) do
          local mp = try(function() return {x = m.unit.pos.x, y = m.unit.pos.y, z = m.unit.pos.z} end)
          if mp and tp then
            local d = cheb(mp, tp)
            if d <= M.SO_ARRIVE then near_n = near_n + 1 end
            if d <= M.SO_ADJ then adj_n = adj_n + 1 end
          end
        end
        if near_n > 0 and not so.arrived then
          so.arrived = true
          so_event(K, key, 'arrived', string.format('sortie %s arrived at %s after %d ticks (%d of %d near)', key, pstr(tp),
                   now - so.t0, near_n, info.n), {n = near_n, pos = {tp.x, tp.y, tp.z}, ticks = now - so.t0})
        end
        if so.kind == 'station' then
          if so.arrived then
            local hs = hostiles_near(K, tp, c.kill_near)
            if #hs > 0 then
              local ids = {}
              for _, h in ipairs(hs) do ids[#ids + 1] = h.id end
              table.sort(ids)
              local ok2 = so_begin(K, key, s, {kind = 'kill', units = ids}, {cmd = so.cmd, by = so.by, keep = so.keep})
              if ok2 then
                so_event(K, key, 'go', string.format('sortie %s: arrived and %d hostile%s within %d tiles: kill order on %s', key,
                         #ids, #ids == 1 and '' or 's', c.kill_near, so_ids_txt(ids)), {units = ids, why = 'kill', pos = {tp.x, tp.y, tp.z}})
              end
            else
              so_end(K, key, 'done', 'no_target', string.format('sortie %s ended at %s: nobody within %d tiles to attack', key,
                     pstr(tp), c.kill_near))
            end
          end
        else
          -- a kill order: soldiers beside the target and no attack
          if adj_n > 0 then
            so.adj = so.adj + dt
            local w = sum_wounds(so.ids[1])
            if so.w0 == nil then so.w0 = w end
            if w ~= so.w0 then so.adj, so.w0 = 0, w end      -- it was hit: the attack is on
          else so.adj, so.w0 = 0, nil end
          if so.adj >= c.idle_ticks then
            local id = so.ids[1]
            if so.keep then K.call('reflex', 'ignore', id, 'not_attackable') end     -- only a lone harmless one is cleared
            so_end(K, key, 'abort', 'not_attackable', string.format('sortie %s ended: soldiers stood beside %s for %d ticks and no ' ..
                   'attack came: DF does not treat it as an enemy (visitor, diplomat, captive or a child?)%s',
                   key, so_ids_txt(so.ids), so.adj, so.keep and '; the unit is cleared' or ''))
          elseif order_count(s) == 0 then
            -- DF dropped the order while the target lives
            if so.re >= M.SO_REISSUE then
              so_end(K, key, 'abort', 'order_dropped', string.format('sortie %s ended: DF dropped the kill order %d times while %s lives',
                     key, so.re, so_ids_txt(so.ids)))
            else
              local ok2 = K.act.squad_order(s.id, {kind = 'kill', units = so.ids})
              so.re = so.re + 1
              if not ok2 then so.re = M.SO_REISSUE end
            end
          end
        end
      end
    end
    ::continue::
  end
  return next(rt.so) ~= nil
end

-- the ids (of `ids`) when the census shows a lone harmless intruder picture around them, else nil
function M.lone_of(K, ids)
  if type(ids) ~= 'table' then return nil, 'stale' end
  local ok, l, why = K.call('reflex', 'lone_ids')
  if not (ok and type(l) == 'table' and #l > 0) then return nil, ok and why or 'stale' end
  local have = {}
  for _, id in ipairs(l) do have[id] = true end
  for _, id in ipairs(ids) do if not have[id] then return nil, 'group' end end
  return l
end

-- public (reflex, BREACH: a lone harmless intruder inside Kern+ for confine.kill_hours): the best squad gets a kill order on
-- it. Returns true, msg (running or started) or false, why
function M.kill_lone(K, ids, by)
  if K.mode() == 'PEACE' then return false, 'PEACE' end
  local key = M.sortie_squad(K)
  if not key then return false, 'no squad to send' end
  if rt.so[key] then return true, 'sortie ' .. key .. ' is running' end
  local e = st.sq[key]
  local s = e and squad(e.id)
  local c = so_conf(K)
  local info = s and M.squad_info(K, key)
  if not info or info.n == 0 then return false, 'squad ' .. key .. ' has no members' end
  if info.worn < c.worn then return false, string.format('squad %s worn %d%% < %d%%', key, info.worn, c.worn) end
  local seen = {}
  for _, h in ipairs(type(K.census.h) == 'table' and K.census.h.list or {}) do seen[h.id] = true end
  local vis = {}
  for _, id in ipairs(ids or {}) do if seen[id] then vis[#vis + 1] = id end end
  table.sort(vis)
  if #vis == 0 then return false, 'the target is not in sight' end
  local p = unit_xyz(vis[1])
  local why = p and unreachable(K, s, p)
  if why then return false, why end
  local ok, err = so_begin(K, key, s, {kind = 'kill', units = vis}, {cmd = 'kernel', by = by or 'reflex', keep = true})
  if not ok then return false, err end
  rt.so[key].tgt = p
  so_event(K, key, 'go', string.format('sortie %s: the kernel orders a kill on %s %s inside the fort (%d soldiers)', key,
           #vis == 1 and 'the lone harmless intruder' or 'the harmless intruders', so_ids_txt(vis), info.n),
           {units = vis, why = 'kill', pos = p and {p.x, p.y, p.z} or nil, n = info.n, worn = info.worn})
  return true, 'kill order on ' .. so_ids_txt(vis)
end

-- public (tests, status): the running position sortie of a squad, or nil
function M.sortie_of(K, key)
  local so = rt.so[key]
  if not so then return nil end
  return {kind = so.kind, ids = so.ids, keep = so.keep, arrived = so.arrived, by = so.by, t0 = so.t0}
end

-- inbox squad.sortie (approval checked by kern): kill the visible hostiles in a killbox, else move there. A position
-- with a visible hostile within sortie.kill_near tiles is a kill order on it (M3, BUG-113); a killbox id the manifest does
-- not have falls back to a kill order on the one hostile in sight (M3). args.gate (Gordon 2026-10-16): a sortie through that
-- outer bridge; siege runs it (gather in the bailey, open, kill, recall, close) and answers
M.verbs['squad.sortie'] = function(K, args, cmd)
  if args.gate ~= nil then
    local ok, r, msg = K.call('siege', 'sortie', args, cmd and cmd.id)
    if not ok then return false, 'siege: ' .. tostring(r) end
    return r == true, tostring(msg)
  end
  local k = args.squad
  local e = type(k) == 'string' and st.sq[k]
  local s = e and squad(e.id)
  if not s or #members(s) == 0 then return false, 'no squad ' .. tostring(k) end
  local target, order, what = args.target, nil, nil
  local c = so_conf(K)
  local pos_target
  if type(target) == 'string' then
    local x, y, z = target:match('^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')     -- "77,67,128" is a position
    if x then pos_target = posp({tonumber(x), tonumber(y), tonumber(z)}) end
  end
  if type(target) == 'string' and not pos_target then
    local man = K.manifest()
    local box
    for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do if kb.id == target then box = kb end end
    if not box then
      -- M3: no killbox of that name (a fort without a killbox manifest): the one hostile in sight is the target
      local list = type(K.census.h) == 'table' and K.census.h.list or {}
      if #list == 1 then
        local p = {x = list[1].x, y = list[1].y, z = list[1].z}
        local why = unreachable(K, s, p)
        if why then return false, 'no killbox ' .. target .. '; ' .. why end
        order = {kind = 'kill', units = {list[1].id}}
        what = string.format('no killbox %s: kill order on the lone hostile %d at %s', target, list[1].id, pstr(p))
        pos_target = p
      elseif #list == 0 then return false, 'no killbox ' .. target .. ' and no visible hostile; give a position [x,y,z]'
      else return false, string.format('no killbox %s and %d hostiles in sight; give a position [x,y,z]', target, #list) end
    else
      local ids = {}
      for _, h in ipairs(type(K.census.h) == 'table' and K.census.h.list or {}) do ids[#ids + 1] = h.id end
      local t = valid_targets(K, ids, target)
      if #t > 0 then order, what = {kind = 'kill', units = t}, 'kill ' .. #t .. ' in ' .. target
      else order, what = {kind = 'station', pos = geom.bbox_center(box.bbox)}, 'move to ' .. target end
      local ok, err = K.act.squad_order(s.id, order)
      if not ok then return false, 'order failed: ' .. tostring(err) end
      rt.order[k] = 'sortie:' .. tostring(cmd and cmd.id or '?')
      rt.kpi = nil
      return true, 'sortie ' .. k .. ': ' .. what
    end
  else
    local p = pos_target or posp(target)
    if not p then return false, 'target must be a killbox id or [x,y,z]' end
    pos_target = p
    local why = unreachable(K, s, p)
    if why then return false, why end
    local near = hostiles_near(K, p, c.kill_near)
    if #near > 0 then
      local ids = {}
      for _, h in ipairs(near) do ids[#ids + 1] = h.id end
      table.sort(ids)
      order = {kind = 'kill', units = ids}
      what = string.format('kill order on %s (%d visible hostile%s within %d tiles of %s)', so_ids_txt(ids), #ids,
                           #ids == 1 and '' or 's', c.kill_near, pstr(p))
    else
      order, what = {kind = 'station', pos = p}, string.format('move to %s (no visible hostile within %d tiles)', pstr(p), c.kill_near)
    end
  end
  local keep = false
  if order.kind == 'kill' then keep = M.lone_of(K, order.units) ~= nil end
  local ok, err = so_begin(K, k, s, order, {cmd = cmd and cmd.id, by = 'verb', keep = keep})
  if not ok then return false, err end
  rt.so[k].tgt = pos_target or rt.so[k].tgt
  so_event(K, k, 'go', string.format('sortie %s: %s%s', k, what, keep and '; kept against the posture while the squad is worn >= ' ..
           c.worn .. '%' or ''), {why = order.kind, units = order.units, pos = pos_target and {pos_target.x, pos_target.y, pos_target.z} or nil})
  return true, 'sortie ' .. k .. ': ' .. what
end

---------------------------------------------------------------- BUG-055: the squads screen as verbs
-- Run 11 note 25 / Run 14 note 64: the game session replayed act.lua's squad_create / squad_leader / squad_add /
-- squad_uniform by hand in scratch scripts, because they were internal functions only. A player does these on the squads
-- screen; the verbs below are the same actions, for the fight-free modes (kern: PEACE, ALERT, RECOVERY). A squad named A,
-- B or C (squad.create name) is adopted by this module on its next run and equipped like its own.
local function squad_arg(a)
  local e = type(a) == 'string' and st.sq[a] or nil
  local s, key = e and squad(e.id), a
  if type(a) == 'number' then
    s, key = squad(int(a)), nil
    for k, x in pairs(st.sq) do if s and x.id == s.id then key = k end end
  end
  return s, key
end

M.verbs['squad.create'] = function(K, args, cmd)
  if type(args.name) ~= 'string' or args.name == '' then return false, 'squad.create needs a name' end
  local ok, id = K.act.squad_create(args.name, {assignment_id = args.assignment or free_assignment(), leader = args.leader})
  if not ok then return false, 'squad.create: ' .. tostring(id) end
  local s = squad(id)
  local led = s ~= nil and leader_set(s)
  K.log('info', 'military: squad.create %s: id %s%s', tostring(args.name), tostring(id), led and ' with a leader' or ' without a leader')
  return true, string.format('squad %s created (id %s)%s', tostring(args.name), tostring(id),
                             led and '' or ', no leader yet: squad.leader'), {squad = id, leader = led}
end

M.verbs['squad.leader'] = function(K, args, cmd)
  if not int(args.unit) then return false, 'squad.leader needs {squad, unit}' end
  local s = squad_arg(args.squad)
  if not s then return false, 'no squad ' .. tostring(args.squad) end
  local ok, res = K.act.squad_leader(s.id, args.unit)
  if not ok then return false, 'squad.leader: ' .. tostring(res) end
  rt.kpi = nil
  return true, string.format('unit %d leads squad %d (%s)', args.unit, s.id, tostring(res)), {squad = s.id}
end

M.verbs['squad.add'] = function(K, args, cmd)
  if not int(args.unit) then return false, 'squad.add needs {squad, unit}' end
  local s = squad_arg(args.squad)
  if not s then return false, 'no squad ' .. tostring(args.squad) end
  if not leader_set(s) then return false, 'squad ' .. s.id .. ' has no leader: squad.leader first' end
  -- audit I4 (fair play: the squads screen lists living adult citizens only; addToSquad itself takes any figure)
  local u = df.unit.find(int(args.unit))
  if not u or dfhack.units.isDead(u) or not dfhack.units.isCitizen(u) or not dfhack.units.isAdult(u) then
    return false, 'unit ' .. tostring(args.unit) .. ' is not an adult living citizen'
  end
  local ok, res = K.act.squad_add(s.id, args.unit)
  if not ok then return false, 'squad.add: ' .. tostring(res) end
  rt.kpi = nil
  return true, string.format('unit %d joined squad %d', args.unit, s.id), {squad = s.id}
end

-- the uniform template of the squad's kind (M.UNIFORM, the metal sets) for every position, as ensure_uniform gives it
-- to a fresh squad; the weapon guard (BUG-023: the soldiers never take the Miners' and Woodcutters' tools) applies; a
-- `kind` other than the squad's is applied once, the squad stays what military's plan says
M.verbs['squad.uniform'] = function(K, args, cmd)
  local s, key = squad_arg(args.squad)
  local e = key and st.sq[key]
  if not s or not e then return false, 'squad ' .. tostring(args.squad) .. ' is not one of A, B, C (squad.create name A|B|C first)' end
  local kind = args.kind or e.kind
  if kind == 'training' then return M.uniform_training(K, s, key, e) end
  local base = M.UNIFORM[kind]
  if not base then return false, 'no uniform kind ' .. tostring(kind) end
  local guarded = rt.wguard ~= nil and kind ~= 'xbow'
  if guarded then
    local b = {}
    for k2, v in pairs(base) do b[k2] = v end
    b.no_weapon, base = true, b
  end
  rt.mats[key] = rt.mats[key] or best_mats(math.max(1, #members(s)))
  local ok, res = K.act.squad_uniform(s.id, with_mats(base, rt.mats[key]))
  if not ok then return false, 'squad.uniform: ' .. tostring(res) end
  if guarded then
    for _, m in ipairs(members(s)) do nw_set(e, m.pos, true) end
  end
  e.uni, dirty = 1, true                  -- (the squad keeps its kind: military's own plan names it)
  if e.tr then e.tr = nil end             -- FR-89: a metal kind ends the training policy
  rt.kpi = nil
  return true, string.format('squad %s: %s uniform on %s positions', key, kind, tostring(res)), {squad = s.id}
end

-- FR-89: `squad.uniform kind=training`: the weapon slot of every position to the training weapon of its class (M.train_apply),
-- armor and shield stay; the squad keeps the policy (state tr) so recruits and the militia rotation get the same; the positions
-- without a training variant (hammer, mace, pick, ...) are listed in the answer and in kern.log. Refused when no position
-- could take one
function M.uniform_training(K, s, key, e)
  if e.kind == 'xbow' then
    return false, string.format('squad.uniform: squad %s is a crossbow squad: no training crossbow exists (vanilla)', key)
  end
  local tr = M.train_apply(K, s, nil)
  local function list(items)
    local out = {}
    for i, x in ipairs(items) do
      if i > 8 then out[#out + 1] = string.format('+%d', #items - 8); break end
      out[#out + 1] = string.format('%d %s', x.pos, x.cls)
    end
    return table.concat(out, ', ')
  end
  if #tr.set == 0 and tr.held == 0 then
    if tr.fail then return false, 'squad.uniform: ' .. tr.fail end
    return false, string.format('squad.uniform: no position has a training variant: %s',
                                #tr.left > 0 and list(tr.left) or 'the squad has no soldiers')
  end
  e.tr, dirty = 1, true
  rt.kpi = nil
  local parts = {}
  for _, cls in ipairs({'AXE', 'SWORD', 'SPEAR'}) do
    if tr.counts[cls] then parts[#parts + 1] = string.format('%s %d', cls:lower(), tr.counts[cls]) end
  end
  local msg = string.format('squad %s: training weapons on %d positions (%s)%s', key, #tr.set, table.concat(parts, ', '),
                            tr.held > 0 and string.format(', %d had one already', tr.held) or '')
  if #tr.left > 0 then
    msg = msg .. string.format('; unchanged (no training variant): %s', list(tr.left))
    K.log('warn', 'military: squad %s: %d positions keep their weapon (no training variant): %s', key, #tr.left, list(tr.left))
  end
  if tr.fail then msg = msg .. '; refused for some: ' .. tr.fail end
  return true, msg:sub(1, 400), {squad = s.id, set = #tr.set, left = #tr.left}
end

-- FR-89: the training weapons the squads on the training policy wear or are about to: {raw id = positions}. Economy orders
-- the missing ones (plan_training); positions that carry a metal weapon (no variant) count for nothing. Read-only
function M.training_need(K)
  local out = {}
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and e.tr == 1 and squad(e.id)
    if s then
      for _, m in ipairs(members(s)) do
        local cls = M.weapon_class(m)
        local tok = cls ~= 'TRAINING' and cls and M.TRAINING[cls] or nil
        if cls == 'TRAINING' then
          for _, sub in ipairs(weapon_specs(m.p)) do
            local d = sub >= 0 and try(function() return dfhack.items.getSubtypeDef(df.item_type.WEAPON, sub) end)
            if d and tostring(d.id):find('_TRAINING$') then out[d.id] = (out[d.id] or 0) + 1 end
          end
        elseif tok then out[tok] = (out[tok] or 0) + 1 end
      end
    end
  end
  return out
end

-- BUG-055 (Run 11 note 25): the militia posts as the squads see them, for `inspect offices` and the DECISION text:
-- {active = codes of the ACTIVE militia positions, free = vacant assignments without a squad, squads = fort squads,
-- fails = failed squad creations, why = the sentence for the player (nil while all is well)}
function M.leader_state(K)
  local r = {active = {}, free = 0, squads = 0, fails = rt and rt.create_fails or 0}
  try(function()
    local ent = df.global.plotinfo.main.fortress_entity
    local codes = {}
    for _, p in ipairs(ent.positions.own) do
      if M.SQUAD_POSITIONS[p.code] then
        codes[p.id] = p.code
        if p.flags.ACTIVE then r.active[#r.active + 1] = p.code end
      end
    end
    for _, a in ipairs(ent.positions.assignments) do
      if codes[a.position_id] and a.histfig == -1 and a.squad_id == -1 then r.free = r.free + 1 end
    end
  end)
  table.sort(r.active)
  for _ in pairs(st and st.sq or {}) do r.squads = r.squads + 1 end
  if rt and rt.create_why then
    r.why = string.format('squad creation refused %d time(s): %s (ACTIVE militia posts: %s; vacant assignments without a '
                          .. 'squad: %d)', r.fails, rt.create_why:sub(1, 80), #r.active > 0 and table.concat(r.active, ',')
                          or 'none', r.free)
    r.since = rt.create_since
  end
  return r
end

---------------------------------------------------------------- intake waves and the sortie (siege, Gordon 2026-10-16)
local function order_sig(o)
  if o.kind == 'station' and o.pos then return string.format('station:%d,%d,%d', o.pos.x, o.pos.y, o.pos.z) end
  if o.kind == 'kill' then return 'kill:' .. table.concat(o.units or {}, ',') end
  return tostring(o.kind)
end

-- public (siege, the sortie through O1): squad `key` gets `order` ({kind = 'station', pos = {x, y, z} | [x, y, z]} or
-- {kind = 'kill', units = {ids}}) and keeps it: no posture, re-assert or kill order replaces it until release(key).
-- Idempotent (the same order is not issued again). Returns ok, msg.
function M.hold_order(K, key, order, tag)
  local e = type(key) == 'string' and st.sq[key]
  local s = e and squad(e.id)
  if not s then return false, 'no squad ' .. tostring(key) end
  if type(order) ~= 'table' then return false, 'order required' end
  local o = {kind = order.kind, units = order.units}
  if order.kind == 'station' then
    o.pos = posp(order.pos)
    if not o.pos then return false, 'station needs a pos' end
  elseif order.kind ~= 'kill' or type(order.units) ~= 'table' or #order.units == 0 then
    return false, 'order must be a station or a kill list'
  end
  local sig = 'hold:' .. tostring(tag or '') .. ':' .. order_sig(o)
  if rt.held[key] and rt.order[key] == sig and order_count(s) > 0 then return true, 'kept' end
  local ok, err = K.act.squad_order(s.id, o)
  if not ok then return false, 'order failed: ' .. tostring(err) end
  rt.order[key], rt.held[key], rt.station[key] = sig, true, o.pos
  rt.kpi = nil
  return true, 'ordered'
end

-- public (siege): the held squad gets its posture orders again
function M.release(K, key)
  if not rt.held[key] then return true end
  rt.held[key], rt.order[key] = nil, nil
  rt.kpi = nil
  return apply_squad(K, key, true)
end

---------------------------------------------------------------- BUG-032: stations and the bridges (siege)
-- public (siege): the station posture P gives a squad of `kind` (default melee) now, {x, y, z} or nil: siege names
-- the core station of the deep defense with it
function M.station_for(K, P, kind)
  local man = K.manifest()
  local stations = type(man.stations) == 'table' and man.stations or {}
  local _, pos = posture_station(K, man, stations, P, kind or 'melee', true)
  return pos and {pos.x, pos.y, pos.z} or nil
end

-- public (siege, the sortie's gathering point): `pos` clear of every bridge footprint (moved to the nearest revealed
-- floor on the inner side of the footprints that hold it), {x, y, z}; the position itself when none is found
function M.safe_pos(K, pos, name)
  local p = posp(pos)
  if not p then return nil end
  local man = K.manifest()
  local r = pick(K, man, type(man.stations) == 'table' and man.stations or {}, {{name = name or 'pos', pos = p}})
  note_pick(K, r)
  local q = r.pos or p
  return {q.x, q.y, q.z}
end

-- the fort squad of a soldier and its station order (the squads screen's move order): {sid, p} or nil
local function station_order(uid)
  return try(function()
    local u = df.unit.find(uid)
    local sid = u and int(u.military.squad_id)
    if not sid or sid < 0 then return nil end
    local s = squad(sid)
    if not s then return nil end
    for _, o in ipairs(s.orders) do
      local okp, x, y, z = pcall(function() return o.pos.x, o.pos.y, o.pos.z end)
      if okp and int(x) and int(y) and int(z) and x >= 0 then return {sid = sid, s = s, p = geom.pos(x, y, z)} end
    end
    return nil
  end)
end

local function key_of(sid)
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    if e and e.id == sid then return sp.key end
  end
end

-- one squad whose soldiers stand at its station on or next to footprint fp of bridge `bname`: a station whose crowd
-- (the farthest of them from the station, q.o) stays out of the ring, on that bridge's inner side; true if ordered
local function restation_one(K, man, stations, bname, fp, q, clear, margin)
  local key = key_of(q.sid)
  if key and rt.held[key] then return false end            -- siege's sortie owns that squad's orders
  local need = math.max(clear, margin + q.o)
  local side = SL.side(man, fp, q.p, clear)
  local chain = {{name = 'station', pos = q.p}}
  if key then
    local e = st.sq[key]
    local _, ch = station_of(K, man, st.posture, e.kind, key == first_melee_key(), stations)
    for _, ent in ipairs(ch or {}) do chain[#chain + 1] = ent end
  end
  for _, n in ipairs({'core', 'b2', 'z4'}) do chain[#chain + 1] = n end
  local r = pick(K, man, stations, chain, {need_by = {[bname] = need}, side = side, all = true, bridge = bname,
                                           tag = bname .. ':' .. need})
  local label = key and string.format('squad %d (%s)', q.sid, key) or string.format('squad %d', q.sid)
  local head = string.format('%s holds the raise of %s: soldier %d %d tile%s from its footprint, %d from the squad\'s '
                             .. 'station %s', label, bname, q.ids[1], q.d, q.d == 1 and '' or 's', q.o, pstr(q.p))
  local d = {why = 'hold', squad = q.sid, key = key, bridge = bname, from = geom.arr(q.p), units = q.ids,
             d = q.d, first = 'station'}
  if not r.pos or (r.pos.x == q.p.x and r.pos.y == q.p.y and r.pos.z == q.p.z) then
    rt.rs_note = rt.rs_note or {}
    local nk, now = q.sid .. ':' .. bname, now_tick(K)
    if rt.rs_note[nk] and now >= rt.rs_note[nk] and now - rt.rs_note[nk] < M.NOTE_EVERY then return false end
    rt.rs_note[nk] = now
    d.why, d.station = 'none', 'station'
    local txt = head .. string.format(': no station clear of it on its inner side (crowd %d tiles): kept', need)
    K.emit('STATION_MOVED', 'B', txt:sub(1, 200), d)
    K.log('warn', 'military: %s', txt)
    return false
  end
  if key then
    local _, _, src = posture_station(K, man, stations, st.posture, st.sq[key].kind, key == first_melee_key())
    rt.over[key] = {P = st.posture, src = src, pos = r.pos, bridge = bname}
    apply_squad(K, key, true)
  elseif not K.act.squad_order(q.sid, {kind = 'station', pos = r.pos}) then
    return false
  end
  rt.kpi = nil
  d.station, d.to = r.name, geom.arr(r.pos)
  local txt = head .. string.format(': re-stationed at %s (%s)', pstr(r.pos), r.name)
  K.emit('STATION_MOVED', 'B', txt:sub(1, 200), d)
  K.log('warn', 'military: %s', txt)
  return true
end

-- public (BUG-032, siege): soldiers hold a raise (gate.holds(): the bridges waiting for units on or next to their
-- footprint). Every fort squad with a station order whose soldiers stand at it (within stations.spread + 1 tiles of
-- it, or the station itself within the clearance of that footprint) gets a station clear of the bridge at once (the squads
-- screen's move order): its station moved away on the bridge's inner side far enough that the crowd stays out of the
-- ring, else the next station of the posture's chain, the core station, b2 or the core level (z4). A squad military
-- leads keeps it for the posture (rt.over); a squad on a kill order or held for a sortie is left alone. Soldiers only
-- passing through (farther from their station) are not moved: the raise waits for them as before. Returns the number
-- of squads ordered.
function M.restation(K, holds)
  if type(holds) ~= 'table' then return 0 end
  local man = K.manifest()
  local stations = type(man.stations) == 'table' and man.stations or {}
  local clear, margin = clearance(K)
  local crowd = spread(K) + 1                 -- a soldier this close to his squad's station stands at it
  local n = 0
  for _, h in ipairs(holds) do
    local fp = type(h) == 'table' and h.want == 'up' and type(h.bridge) == 'string' and SL.fp(h.fp)
    if fp then
      local by, order = {}, {}
      for _, e in ipairs(type(h.units) == 'table' and h.units or {}) do
        local x, y, z = int(e.x), int(e.y), int(e.z)
        local so = e.k == 'soldier' and x and y and z and station_order(e.id)
        if so and so.p.z == z then
          local o = math.max(math.abs(x - so.p.x), math.abs(y - so.p.y))
          local ds = SL.dist(fp, so.p.x, so.p.y, so.p.z)
          if o <= crowd or (ds and ds <= clear) then
            local q = by[so.sid]
            if not q then
              q = {sid = so.sid, p = so.p, o = 0, ids = {}, d = int(e.d) or 0}
              by[so.sid], order[#order + 1] = q, so.sid
            end
            if o > q.o then q.o = o end
            q.ids[#q.ids + 1] = e.id
          end
        end
      end
      table.sort(order)
      for _, sid in ipairs(order) do
        if restation_one(K, man, stations, h.bridge, fp, by[sid], clear, margin) then n = n + 1 end
      end
    end
  end
  if n > 0 then save(K) end
  return n
end

-- public (siege): squad members (alive) of squad `key` (nil = every squad) inside any of `boxes` ({x0,y0,z0,x1,y1,z1}):
-- n inside, n members, ids inside, ids outside the boxes (<= 20 each). posture_only: only the squads that follow their
-- posture's station (not those on a sortie, a held order or a kill order)
function M.members_in(K, key, boxes, posture_only)
  local n_in, n, ins, outs = 0, 0, {}, {}
  for _, sp in ipairs(M.SQUADS) do
    local cur = rt.order[sp.key] or ''
    local own = posture_only == true and (rt.held[sp.key] or cur:sub(1, 7) == 'sortie:' or cur:sub(1, 5) == 'kill:')
    local e = (key == nil or sp.key == key) and not own and st.sq[sp.key]
    local s = e and squad(e.id)
    for _, m in ipairs(s and members(s) or {}) do
      local p = try(function() return {x = m.unit.pos.x, y = m.unit.pos.y, z = m.unit.pos.z} end)
      n = n + 1
      local hit = false
      for _, b in ipairs(p and boxes or {}) do if geom.in_bbox(p, b) then hit = true; break end end
      if hit then
        n_in = n_in + 1
        if #ins < 20 then ins[#ins + 1] = m.unit.id end
      elseif #outs < 20 then outs[#outs + 1] = m.unit.id end
    end
  end
  table.sort(ins)
  table.sort(outs)
  return n_in, n, ins, outs
end

-- public (siege, the sortie's check): {n = members, cv = combat value summed, worn = %, ids} of squad `key`, or nil
function M.squad_info(K, key)
  local e = type(key) == 'string' and st.sq[key]
  local s = e and squad(e.id)
  if not s then return nil end
  local r = {n = 0, cv = 0, worn = 0, ids = {}}
  local slots, worn = 0, 0
  for _, m in ipairs(members(s)) do
    r.n = r.n + 1
    r.ids[#r.ids + 1] = m.unit.id
    r.cv = r.cv + M.cv(m.unit)
    local a, b = uniform_counts(m.p, m.unit, e.kind)
    slots, worn = slots + a, worn + b
  end
  table.sort(r.ids)
  r.worn = pct(worn, slots)
  return r
end

---------------------------------------------------------------- loot and free metal gear (FR-46)
local LOOT_SKIP = {'trader', 'in_building', 'garbage_collect', 'removed', 'owned', 'in_job', 'construction', 'hostile'}
local function is_metal(it)
  local mi = dfhack.matinfo.decode(it)
  local fl = mi and mi.material and mi.material.flags
  return fl and fl.IS_METAL == true or false
end

-- a revealed tile on the citizens' walk group (no snapshot module: revealed and reachable are unknown -> yes)
local function reachable_tile(K, x, y, z)
  local okt, t = K.call('snapshot', 'tile', x, y, z)
  if okt and type(t) ~= 'table' then return false end
  local okf, far = K.call('snapshot', 'far', x, y, z)
  return not (okf and far == true)
end

-- one gear item: counted as free metal (returns 1 or the ammo units), or unforbidden as loot when `loot`
-- and the budget allows (returns the units and true)
local function loot_item(K, it, cat, loot, budget)
  local f = it.flags
  local units = cat == 'ammo' and math.max(1, math.tointeger(it.stack_size) or 1) or 1
  if not f.forbid then
    if free_item(it) and is_metal(it) then return units end
    return 0
  end
  if not loot or budget <= 0 or f.in_inventory then return 0 end
  for _, k in ipairs(LOOT_SKIP) do if f[k] then return 0 end end
  if not is_metal(it) then return 0 end
  local x, y, z = dfhack.items.getPosition(it)
  if x and reachable_tile(K, x, y, z) and K.act.item_flag(it.id, 'forbid', false) then return units, true end
  return 0
end

-- one pass over the gear vectors: free metal per category; forbidden loot unforbidden when `loot`
local function loot_pass(K, loot)
  local free, n = {}, 0
  for _, e in ipairs(M.LOOT.cats) do
    free[e[2]] = 0
    local vec = try(function() return df.global.world.items.other[e[1]] end)
    for _, it in ipairs(vec or {}) do
      local ok, units, took = pcall(loot_item, K, it, e[2], loot, M.LOOT.per_run - n)
      if ok then
        free[e[2]] = free[e[2]] + units
        if took then n = n + 1 end
      else rt.loot_err = (rt.loot_err or 0) + 1 end
    end
  end
  return free, n
end

local function loot(K)
  local now = now_tick(K)
  if rt.loot_t and now - rt.loot_t < M.LOOT.every then return end     -- every LOOT.every ticks in any mode
  rt.loot_t = now
  local mode = K.mode()
  local h = K.census.h
  local quiet = type(h) == 'table' and (int(h.vis) or 0) == 0
  local go = mode == 'PEACE' or (mode == 'RECOVERY' and quiet)
  local free, n = loot_pass(K, go)
  rt.free = free
  if n > 0 then K.log('info', 'loot: %d forbidden metal weapons, armor and ammo unforbidden for the armory', n) end
end

---------------------------------------------------------------- BUG-050: the monthly uniform-unstick
-- Run 14 (y529-y535): the armor coverage fell from 53 % to 4 % several times. military ran `uniform-unstick --all --drop
-- --free` every month in PEACE, whatever the uniforms looked like, and `--drop` makes every soldier drop what the uniform
-- names; the dropped kit lay on the floor and the soldiers hung in PickupEquipment for weeks. Now: `--all --free` only,
-- and only while a uniform slot is empty (worn < unstick.below, 100); `--drop` only on an opt-in (unstick.drop) and
-- only once `drop_after` plain runs in a row found the same proven conflict (a soldier wearing an armor piece no
-- spec of his category holds while that category has an empty slot: M.conflicts), never in a lockdown or with a
-- hostile in sight. kern.log names the worn % before and a day and a week after every run.
M.US_LOOK = {1200, 8400}

-- the armor item type of a uniform category (weapons and shields are the tool details' business)
M.CAT_TYPE = {body = 'ARMOR', head = 'HELM', pants = 'PANTS', gloves = 'GLOVES', shoes = 'SHOES'}

-- does this soldier wear an item of a category's type that none of its specs holds, while a spec of the category is empty?
local function conflict(p, u)
  return try(function()
    local R, worn = roles(), {}
    for _, inv in ipairs(u.inventory) do
      if R[inv.mode] and inv.item then worn[inv.item.id] = inv.item:getType() end
    end
    for cat, tname in pairs(M.CAT_TYPE) do
      local ty, own, empty = df.item_type[tname], {}, false
      for _, sp in ipairs(p.equipment.uniform[cat]) do
        local hit = false
        if int(sp.item) ~= nil and sp.item >= 0 then own[sp.item] = true; hit = worn[sp.item] ~= nil end
        for _, id in ipairs(sp.assigned or {}) do own[id] = true; if worn[id] then hit = true end end
        if not hit then empty = true end
      end
      if empty then
        for id, t in pairs(worn) do if t == ty and not own[id] then return true end end
      end
    end
    return false
  end) == true
end

-- soldiers with a proven conflict, and their ids
function M.conflicts(K)
  local n, who = 0, {}
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    for _, m in ipairs(s and members(s) or {}) do
      if conflict(m.p, m.unit) then n, who[#who + 1] = n + 1, m.unit.id end
    end
  end
  return n, who
end

-- not PEACE (ALERT, SIEGE, BREACH, RECOVERY, DRILL), a lockdown holds, or a hostile is in sight: the reason, else nil.
-- military's repairs and drill's start both ask (BUG-050, BUG-051), and the militia turnover (FR-79).
-- BUG-087: "a hostile in sight" was the raw census count, a second opinion beside threat's. threat counts for nothing
-- the hostiles reflex cleared (BUG-065: a harmless intruder released at the confinement limit; Run 11: an invader whose
-- lockdown expired far, reflex.far_ids) and the wildlife out of reach (an ELK_BIRD at the map edge, a beast in a sealed
-- cavern); military kept counting them as long as they were in sight (Run 14: a gremlin for years), so the unstick, the
-- drill and the turnover waited for them for ever. Now threat's reading decides (its `hostile`: an invader not cleared,
-- a hostile inside or in reach), and a great danger, an undead and a hostile the census list does not show (it holds the
-- nearest LIST_MAX) still count; without a threat module or a scan every hostile in sight counts, as before.
function M.danger(K)
  local mode = K.mode()
  if mode ~= 'PEACE' then return 'mode ' .. mode end
  local okr, why = K.call('reflex', 'holding')
  if okr and why then return 'lockdown' end
  local h = K.census.h
  if type(h) ~= 'table' or (int(h.vis) or 0) == 0 then return nil end
  local oka, a = K.call('threat', 'assess')
  if not (oka and type(a) == 'table') then return 'hostile' end
  local listed = type(h.list) == 'table' and #h.list or 0
  if a.hostile or (a.great or 0) > 0 or (a.undead or 0) > 0 or int(h.vis) > listed then return 'hostile' end
  return nil
end

-- the worn % after a run (kern.log), the run itself
function M.unstick(K, now)
  local c = M.conf(K).unstick
  local worn = rt.kpi and rt.kpi.worn or 0
  if st.unstick and st.us_w and rt.us_i and M.US_LOOK[rt.us_i] and now - st.unstick >= M.US_LOOK[rt.us_i] then
    K.log('info', 'military: uniform-unstick %d ticks ago (%s): worn %d%% before, %d%% now', now - st.unstick,
          st.us_a or '?', st.us_w, worn)
    rt.us_i = rt.us_i + 1
  end
  if not c.on or (st.unstick ~= nil and now - st.unstick < c.every) then return end
  if worn >= c.below or M.danger(K) then return end
  local n = M.conflicts(K)
  st.us_n = n > 0 and (int(st.us_n) or 0) + 1 or 0
  local args = {'uniform-unstick', '--all', '--free'}
  if c.drop and st.us_n > c.drop_after then
    args = {'uniform-unstick', '--all', '--drop', '--free'}
    K.log('warn', 'military: uniform-unstick --drop: %d soldiers keep an armor piece no spec holds after %d plain runs',
          n, st.us_n - 1)
    st.us_n = 0
  end
  K.act.run(table.unpack(args))
  st.unstick, st.us_w, st.us_a, dirty = now, worn, table.concat(args, ' ', 2), true
  rt.us_i = 1
end

-- FR-71: a militia squad's window opens or closes (kern.log once per change; the first look only records)
function M.windows(K)
  local c = M.conf(K)
  local month = (try(function() return df.global.cur_year_tick end) or 0) // 33600
  rt.win = rt.win or {}
  for _, sp in ipairs(M.SQUADS) do
    local set = c.militia[sp.key]
    if set then
      local on = set[month] == true
      if rt.win[sp.key] ~= nil and rt.win[sp.key] ~= on then
        local e = st.sq[sp.key]
        local s = e and squad(e.id)
        local ms = {}
        for m in pairs(set) do ms[#ms + 1] = m end
        table.sort(ms)
        local cu = K.census.u
        K.log('info', 'military: militia squad %s %s (months %s): %d members, %d citizens', sp.key,
              on and 'on duty' or 'off duty', #ms > 0 and (ms[1] .. '-' .. ms[#ms]) or '-', s and #members(s) or 0,
              type(cu) == 'table' and cu.cit or 0)
      end
      rt.win[sp.key] = on
    end
  end
end

---------------------------------------------------------------- KPIs
-- BUG-052: the tiles around its station point a squad of n stands in: DF spreads the soldiers over the tiles around the
-- point (a block in a room, a line along a corridor: Run 11 y497 read 'on_station 0' beside soldiers who stood in the
-- gatehouse); conf station_r (3) + one tile per four soldiers beyond the first
function M.station_radius(n, base)
  return (base or M.STATION_R) + math.max(0, ((n or 1) - 1) // 4)
end

-- why a soldier is not at his squad's station (kpi off): 'equip' (a PickupEquipment job: the kit lies on the floor,
-- BUG-050), 'hurt' (a wound, unconscious, thirsty or hungry past SIEGE_THIRST/HUNGER), 'level' (another z), else 'far'
local function off_reason(u, up, spos)
  local jt = try(function() local j = u.job and u.job.current_job; return j and j.job_type end)
  local pk = df.job_type and df.job_type.PickupEquipment
  if pk ~= nil and jt == pk then return 'equip' end
  if not healthy(u) then return 'hurt' end
  if up.z ~= spos.z then return 'level' end
  return 'far'
end

local function compute(K)
  local k = {squads = 0, soldiers = 0, worn = 0, cv = 0, metal_pct = 0, on_station = 0}
  local slots, worn, specs, cv, metal = 0, 0, 0, 0, 0
  local conf, off = M.conf(K), {}
  local man = K.manifest()
  local stations = type(man.stations) == 'table' and man.stations or {}
  local first = first_melee_key()
  for _, sp in ipairs(M.SQUADS) do
    local e = st.sq[sp.key]
    local s = e and squad(e.id)
    if s then
      local mem = members(s)
      if #mem > 0 then k.squads = k.squads + 1 end
      local spos = rt.station[sp.key]
      local R = M.station_radius(#mem, conf.station_r)
      -- the posture names a station for this squad and none was found (no manifest station): all of them are off it
      local want = false
      if not spos and #mem > 0 and st.posture then
        local _, chain = station_of(K, man, st.posture, e.kind, sp.key == first, stations)
        want = chain ~= nil
      end
      for _, m in ipairs(mem) do
        local u = m.unit
        k.soldiers = k.soldiers + 1
        local a, b, c = uniform_counts(m.p, u, e.kind)
        slots, worn, specs = slots + a, worn + b, specs + c
        cv = cv + M.cv(u)
        if iron_or_steel(u) then metal = metal + 1 end
        if spos then
          local up = try(function() return {x = u.pos.x, y = u.pos.y, z = u.pos.z} end)
          if up and up.z == spos.z and geom.dist(up, spos) <= R then k.on_station = k.on_station + 1
          elseif up then
            local why = off_reason(u, up, spos)
            off[why] = (off[why] or 0) + 1
          end
        elseif want then
          off.nost = (off.nost or 0) + 1
        end
      end
    end
  end
  k.worn = pct(worn, slots)
  k.metal_pct = pct(metal, k.soldiers)
  if k.soldiers > 0 then k.cv = (2 * cv + k.soldiers) // (2 * k.soldiers) end
  k.slots, k.specs = slots, specs
  if next(off) then k.off = off end
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
        unstick = int(p.unstick), us_w = int(p.us_w), us_n = int(p.us_n), early = int(p.early) == 1 and 1 or nil,
        us_a = type(p.us_a) == 'string' and p.us_a:sub(1, 40) or nil}
  for _, sp in ipairs(M.SQUADS) do
    local e = type(p.sq) == 'table' and p.sq[sp.key]
    if type(e) == 'table' and int(e.id) then
      local nw
      if type(e.nw) == 'table' then
        for _, p in ipairs(e.nw) do if int(p) then nw = nw or {}; nw[#nw + 1] = int(p) end end
      end
      st.sq[sp.key] = {id = int(e.id), kind = sp.kind, uni = int(e.uni) == 1 and 1 or 0,
                       auto = int(e.auto) == 1 and 1 or nil, nw = nw, tr = int(e.tr) == 1 and 1 or nil}
    end
  end
  -- FR-79: rot[key] = {c = absolute month of the last window close whose members were credited, e = of the last one whose
  -- turnover ended, t = tick of the last batch, me = members swapped at the open edge, n = turnovers, mv = members changed,
  -- ms = lapsed turnovers, lw = how the last one ended}; served[unit id] = militia windows served (JSON keys come back
  -- as strings)
  st.rot, st.served = {}, {}
  if type(p.rot) == 'table' then
    for _, sp in ipairs(M.SQUADS) do
      local r = p.rot[sp.key]
      if type(r) == 'table' and int(r.c) and int(r.e) then
        st.rot[sp.key] = {c = int(r.c), e = int(r.e), t = int(r.t), n = int(r.n) or 0, mv = int(r.mv) or 0,
                          ms = int(r.ms) or 0, me = int(r.me), lw = type(r.lw) == 'string' and r.lw:sub(1, 60) or nil}
      end
    end
  end
  if type(p.served) == 'table' then
    for k, v in pairs(p.served) do
      local id, n = int(tonumber(k)), int(v)
      if id and n and n > 0 then st.served[id] = n end
    end
  end
  rt = {retry = {}, order = {}, station = {}, kpi = nil, kpi_tick = 0, create_fails = 0, mats = {}, wk = {},
        no_wpn = {}, held = {}, over = {}, rot = {}, add_bad = {}, add_note = {}, rot_why = {}, rot_t = {}, rot_last = {},
        so = {}}
  dirty = false
  M.every = {ticks = K.mode() == 'PEACE' and M.SLOW or M.FAST}
end

-- Run 11 siege 3: the wants in a siege: the first melee squad (by the plan, the tools-first rule ignored) at least
-- HOLD_MIN, the others their targets
SIEGE_FILL = {SIEGE = true, BREACH = true}
function hold_floor(K, per)
  local r = {}
  for k, v in pairs(per) do r[k] = v end
  for _, sp in ipairs(active(K)) do
    if sp.kind == 'melee' then
      if (r[sp.key] or 0) < M.HOLD_MIN then r[sp.key] = M.HOLD_MIN end
      break
    end
  end
  return r
end

-- a squad below half its want in a siege and nobody in the core to refill it: kern.log says why, at most every
-- NOTE_EVERY ticks per squad
function siege_short(K, k, s, want, recruits, why)
  local n = #members(s)
  if n >= (want + 1) // 2 or #recruits() > 0 then return end
  local now = now_tick(K)
  rt.sf_note = rt.sf_note or {}
  if rt.sf_note[k] and now >= rt.sf_note[k] and now - rt.sf_note[k] < M.NOTE_EVERY then return end
  rt.sf_note[k] = now
  why = why or {}
  K.log('warn', 'military: %s: squad %s %d of %d and no healthy civilian in the core to refill it (in the refuge %d, '
        .. 'outside the core %d, hurt %d, in squads %d, sole key labor %d, nobles %d, moods %d%s)', K.mode(), k, n, want,
        why.refuge or 0, why.outside or 0, why.hurt or 0, why.squad or 0, why.sole or 0, why.noble or 0, why.mood or 0,
        why.no_core and ', no Kern+ burrow' or '')
end

function M.step(K, budget, ctx)
  local now = now_tick(K)
  local mode = K.mode()
  local want_every = mode == 'PEACE' and M.SLOW or M.FAST
  local so_run = sortie_pass(K, now)                                -- M3 (BUG-113)
  if so_run and want_every > M.SO_EVERY then want_every = M.SO_EVERY end
  if M.every.ticks ~= want_every then M.every = {ticks = want_every} end
  if so_run and rt.up_t and now >= rt.up_t and now - rt.up_t < M.FAST then return end   -- the full upkeep keeps its own pace
  rt.up_t = now
  if type(K.census.u) ~= 'table' then return end
  local soldiers = rt.kpi and rt.kpi.soldiers or 0
  if mode == 'PEACE' and soldiers > 0 then M.unstick(K, now) end    -- BUG-050
  M.windows(K)                                                      -- FR-71
  local _, per, zero, short, gear = M.targets(K)
  if zero and mode == 'PEACE' then release(K, zero)
  elseif short and mode == 'PEACE' then release(K, 'tools', 'melee') end
  M.gear_note(K, gear)
  if gear then per = gear.fill end                                    -- Run 11: the squads follow the gear
  local siege = SIEGE_FILL[mode] == true
  if siege then per = hold_floor(K, per) end                          -- Run 11 siege 3 (beyond the gear: HOLD_MIN)
  rt.wguard = weapon_guard(K, per)
  rt.wexcess = tool_excess(rt.wguard)
  local list, why
  local function recruits()                                           -- only when needed
    if not list then list, why = M.recruits(K, siege) end
    return list
  end
  for _, sp in ipairs(M.SQUADS) do
    local want = per[sp.key] or 0
    local e = st.sq[sp.key]
    if want > 0 or e then
      local s = ensure_squad(K, sp, recruits)
      if s then
        if want > 0 and not leader_set(s) then seat_leader(K, sp.key, s, recruits) end   -- addToSquad needs one
        ensure_uniform(K, sp.key, s, want)
        ensure_weapons(K, sp.key, s)
        local rot = want > 0 and M.rot_on(K, sp.key)                      -- FR-79: the rotation owns the militia squad
        if rot then
          if M.rot_step(K, sp, s, want, now) then ensure_uniform(K, sp.key, s, want); ensure_weapons(K, sp.key, s) end
        else rot_idle(K, sp.key, 'target 0') end
        local own = rot and not siege                                      -- (in a siege the fill rules stay as they were)
        fill(K, sp.key, s, want, own and M.rot_source(K, s, want) or recruits, siege, own)
        if own and list then drop_seated(list) end
        if siege then siege_short(K, sp.key, s, want, recruits, why) end
      else rot_idle(K, sp.key, 'no squad yet') end
    else rot_idle(K, sp.key, 'no squad') end
  end
  -- review A4 (BUG-055): a refused creation is news only while a wanted squad is missing or leaderless; squads that were
  -- made on the squads screen (verb squad.create, the player) are adopted above without reaching the creation, so
  -- the refusal would stay for good and keep readiness R0 `office` set
  if rt.create_why then
    local open = false
    for _, sp in ipairs(M.SQUADS) do
      local e = st.sq[sp.key]
      if (per[sp.key] or 0) > 0 or e then
        local s = e and squad(e.id)
        if not (s and leader_set(s)) then open = true end
      end
    end
    if not open then rt.create_why, rt.create_since = nil, nil end
  end
  if st.posture == nil then st.posture, st.pt, dirty = 'TRAIN', now, true end
  for _, sp in ipairs(M.SQUADS) do apply_squad(K, sp.key, false) end   -- drift only
  release_tools(K)                                                     -- BUG-023: after the specs settled
  rt.kpi, rt.kpi_tick = compute(K), now
  M.rot_look(K, now)                                                   -- FR-79
  local okl, err = pcall(loot, K)
  if not okl then K.log('warn', 'loot: %s', tostring(err)) end
  save(K)
end

-- Run 11: kern.log names the gear cap when it changes (rt.gear: state mil.cap)
function M.gear_note(K, g)
  local sig = g and string.format('%d/%d/%d/%d', g.melee, g.want, g.sets, g.xbow) or nil
  rt.gear = g
  if sig == rt.gear_sig then return end
  rt.gear_sig = sig
  if not g then K.log('info', 'military: the gear fills every melee position wanted'); return end
  local p = g.parts or {}
  K.log('info', 'military: melee filled to %d of %d: %d gear sets (body armor %d, melee weapons %d, shields %d)%s',
        g.melee, g.want, g.sets, p.body or 0, p.weapon or 0, p.shield or 0,
        g.xbow > 0 and string.format('; metal short: %d more crossbow positions', g.xbow) or '')
end

function M.state(K)
  local k = rt and rt.kpi
  if not k then return {} end
  local mil = {squads = k.squads, soldiers = k.soldiers, worn = k.worn, cv = k.cv, metal_pct = k.metal_pct,
               on_station = k.on_station}
  local g = rt.gear                                  -- Run 11: the melee squads follow the gear
  if g then mil.cap = {sets = g.sets, melee = g.melee, want = g.want, xbow = g.xbow} end
  for key, info in pairs(rt.rot) do                  -- FR-79: the militia rotation per squad (counts, no names)
    local r = {}
    for f, v in pairs(info) do r[f] = v end
    mil.rot = mil.rot or {}
    mil.rot[key] = r
  end
  if rt.free then                                    -- FR-46: free metal gear per category (only the ones held)
    local free = {}
    for cat, n in pairs(rt.free) do if n > 0 then free[cat] = n end end
    if next(free) then mil.free = free end
  end
  return {mil = mil}
end

M.on.MODE = function(K, ev)
  local want = ev.to == 'PEACE' and M.SLOW or M.FAST
  if rt and rt.so and next(rt.so) then want = M.SO_EVERY end    -- M3: a running sortie ends at its next look (PEACE: mode)
  if M.every.ticks ~= want then M.every = {ticks = want} end
end

return M
