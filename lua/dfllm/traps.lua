-- traps (FR-96/97, goal G14 "everything secured with traps"): the upkeep of the fort's traps. Before, the only traps were
-- fortcore stage 4's 41 stone-fall traps in the Z2 hall; status said `traps N` (the audit's cheapest route) and nothing
-- looked at a trap again once built: a cage trap that caught a goblin stayed full, a destroyed trap stayed gone.
-- The traps themselves are placed by the bp template `traps` (dfpilot/bp/traps.py; lanes outside the doors of the ways
-- in, cage traps; or the hall's missing stone-fall traps) and fortcore stage 4. Their manifest fragments list every
-- trap tile (`manifest.traps`: {id, kind, way?, tiles}; Z2 = the hall). Once a game day this module
--   * reads the trap buildings (buildings.other.TRAP: type, built, the re-arm timeout ready_timeout, a cage in a cage
--     trap) and the census of caged units (a caged unit's cage held by a trap = a full cage trap; so is a trap whose
--     cage holds any creature, a caught wild animal too: the cage's CONTAINS_UNIT ref);
--   * publishes state `traps` {n armed of m listed, b built, w of wn ways with every lane tile trapped, f full cage traps,
--     c free empty cages, l listed tiles without a trap building (lost; lh: in the hall), ord the last cage order};
--     a fort whose hall predates the Z2 entry counts the built traps in the Z2 zones (snapshot.traps) as both;
--   * in PEACE only: orders wooden cages (MakeCage, material wood, tag dfllm:traps; act.workorder like coffins) when the
--     free empty cages fall below the full cage traps + the cage traps without a cage + `cage_spare`, at most
--     `cage_batch` at a time and one live order (re-checked after `order_days`). care already marks a captive's cage in
--     a trap for dumping (the trap is reloaded with an empty cage by the game's own job). No mechanism orders here:
--     quickfort orders a placed project's mechanisms (the runner's existing order path) and economy's supply pass owns
--     the mechanism stock (M.need tells it how many listed traps have no building).
--   * BUG-437 (Run 16a i1 Syrupobeyed y378: three citizens, two of them thirsty past 23000, killed by our own stone-fall traps in the
--     Z2 hall, the fort's only way out): stone-fall and weapon traps hit citizens (only cage traps pass them); a citizen death with
--     the incident TRAP (care's DEATH, by = trap) is remembered (`ck` = those within a year in state `traps`) and raises
--     DECISION_NEEDED trap_friendly (A) once a day, with the victims' tiles. plan propose / check hold the hall and the bridge lanes
--     back while the water or food is short or a citizen died so (dfpilot/plan.py trap_hold).
-- Fair play: only our own buildings, items and the census; every action is a manager order a player gives on the work
-- orders screen. Safety: nothing here pulls, forbids, builds or moves anyone; the lanes' safety rules are the template's.
local M = {name = 'traps', every = {ticks = 1200}, verbs = {}, on = {}}

M.DAY = 1200
M.YEAR = 403200                -- BUG-437: ticks of a game year (the window of `ck`)
M.KILL_KEEP = 20               -- BUG-437: citizens killed by our traps remembered
M.CFG = {cage_spare = 2, cage_batch = 5, order_days = 7}
M.TAG = 'dfllm:traps'
local KIND = {CageTrap = 'cage', StoneFallTrap = 'stone', WeaponTrap = 'weapon'}

local st      -- persisted m.traps: {v, ot (tick of the last cage order), oid (its order id), on (amount)}
local pub     -- the state key (nil: nothing listed and no hall)
local last    -- the last tally (M.need, tests)

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function key(x, y, z) return tostring(x) .. ',' .. tostring(y) .. ',' .. tostring(z) end
local function save(K) K.persist.set('m.traps', st) end

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or r == true             -- unknown (no stage API): count it
end

-- a cage holding a creature (its CONTAINS_UNIT ref, Lua API dfhack.items.getGeneralRef): a caught wild animal too,
-- which the census's caged list (hostiles, predators, undead) leaves out; unreadable: no
local function holds_unit(it)
  local ok, r = pcall(function()
    return dfhack.items.getGeneralRef(it, df.general_ref_type.CONTAINS_UNIT) ~= nil
  end)
  return ok and r == true
end
M.holds_unit = holds_unit

-- (a cage in the trap, that cage holds a creature)
local function has_cage(b)
  local ok, r, full = pcall(function()
    for _, ci in ipairs(b.contained_items) do
      if df.item_cagest:is_instance(ci.item) then return true, holds_unit(ci.item) end
    end
    return false, false
  end)
  if not ok then return true, false end  -- unreadable: no reload asked for
  return r == true, full == true
end

-- the trap buildings: {['x,y,z'] = rec}, {[building id] = rec}; rec = {kind, built, armed, cage (cage traps)}
function M.read()
  local idx, ids = {}, {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRAP) do
      local k = KIND[df.trap_type[b.trap_type] or '']
      if k then
        local rt = 0
        pcall(function() rt = int(b.ready_timeout) or 0 end)
        local rec = {kind = k, built = built(b), armed = rt <= 0}
        if k == 'cage' then
          rec.cage, rec.full = has_cage(b)
          rec.full = rec.full or nil
        end
        idx[key(b.centerx, b.centery, b.z)] = rec
        ids[b.id] = rec
      end
    end
  end)
  return idx, ids
end

-- the cage traps holding a caught creature (census u.caged -> its cage -> the building that holds it); the cages
-- that hold a creature anywhere ({[item id] = true})
function M.full(K, ids)
  local busy = {}
  local cu = K.census and K.census.u
  for _, id in ipairs(type(cu) == 'table' and type(cu.caged) == 'table' and cu.caged or {}) do
    pcall(function()
      local u = df.unit.find(id)
      local cage = u and dfhack.units.getContainer(u)
      if cage then
        busy[cage.id] = true
        local h = dfhack.items.getHolderBuilding(cage)
        if h and ids[h.id] then ids[h.id].full = true end
      end
    end)
  end
  return busy
end

-- free empty cages: on the ground or in a stockpile, not forbidden, not in a job, holding no creature
function M.free_cages(busy)
  local n = 0
  pcall(function()
    for _, it in ipairs(df.global.world.items.other.CAGE) do
      local f = it.flags
      if not (f.in_building or f.forbid or f.in_job or f.trader or f.removed or f.garbage_collect or f.dump
              or busy[it.id] or holds_unit(it)) then           -- a caged pet or catch in a stockpile is not free
        n = n + 1
      end
    end
  end)
  return n
end

-- pure: the manifest's trap entries against the trap buildings. armed = built, not re-arming, and a cage trap with an
-- empty cage; a way counts trapped when every tile of its lane has a built trap
function M.tally(entries, idx)
  local r = {n = 0, m = 0, b = 0, w = 0, wn = 0, f = 0, l = 0, lh = 0, cages = 0, nocage = 0}
  for _, e in ipairs(type(entries) == 'table' and entries or {}) do
    if type(e) == 'table' and type(e.tiles) == 'table' and #e.tiles > 0 then
      local way = type(e.way) == 'table'
      if way then r.wn = r.wn + 1 end
      local all = true
      for _, t in ipairs(e.tiles) do
        r.m = r.m + 1
        local rec = type(t) == 'table' and idx[key(t[1], t[2], t[3])] or nil
        if not rec then
          r.l, all = r.l + 1, false
          if e.id == 'Z2' then r.lh = 1 end
        elseif not rec.built then
          all = false
        else
          r.b = r.b + 1
          if rec.kind == 'cage' then
            r.cages = r.cages + 1
            if rec.full then r.f = r.f + 1 elseif not rec.cage then r.nocage = r.nocage + 1 end
          end
          if rec.armed and not rec.full and (rec.kind ~= 'cage' or rec.cage) then r.n = r.n + 1 end
        end
      end
      if way and all then r.w = r.w + 1 end
    end
  end
  return r
end

-- pure: cages to order now: the full cage traps and those without a cage, plus a spare, minus the free ones
function M.cage_need(r, free, cfg)
  if (r.cages or 0) == 0 then return 0 end
  local want = (r.f or 0) + (r.nocage or 0) + cfg.cage_spare
  return math.max(0, math.min(cfg.cage_batch, want - free))
end

-- is our last cage order still on the work orders screen with something left to make?
local function order_live(id)
  if not id then return false end
  local ok, live = pcall(function()
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then return (int(o.amount_left) or 0) > 0 end
    end
    return false
  end)
  return ok and live == true
end

local function conf(K)
  local c = {}
  for k, v in pairs(M.CFG) do c[k] = v end
  local b = type(K.cfg) == 'table' and type(K.cfg.baseline) == 'table' and K.cfg.baseline.traps or nil
  for k, lim in pairs({cage_spare = {0, 20}, cage_batch = {1, 20}, order_days = {1, 60}}) do
    local v = type(b) == 'table' and int(b[k]) or nil
    if v and v >= lim[1] and v <= lim[2] then c[k] = v end
  end
  return c
end

local function order_cages(K, c, r, now)
  local n = M.cage_need(r, r.c, c)
  if n <= 0 or K.mode() ~= 'PEACE' then return nil end
  if order_live(st.oid) then return string.format('MakeCage x%d ordered', st.on or 0) end
  if st.ot and now >= st.ot and now - st.ot < c.order_days * M.DAY then return nil end
  local ok, id = K.act.workorder({job = 'MakeCage', amount_total = n, frequency = 'OneTime', tag = M.TAG,
                                  material_category = {'wood'}})
  st.ot = now
  if ok then
    st.oid, st.on = int(id), n
    K.log('info', 'traps: order %s MakeCage x%d (wood): %d cage traps full, %d without a cage, %d free cages',
          tostring(id), n, r.f, r.nocage, r.c)
    save(K)
    return string.format('MakeCage x%d ordered', n)
  end
  st.oid, st.on = nil, nil
  save(K)
  K.log('warn', 'traps: order MakeCage x%d refused: %s', n, tostring(id))
  return 'MakeCage refused'
end

---------------------------------------------------------------- BUG-437: citizens killed by our own traps
-- the kills within a year before `now`
function M.kills(now)
  local n = 0
  for _, k in ipairs(st and st.kills or {}) do
    if now - k.t < M.YEAR then n = n + 1 end
  end
  return n
end

-- care's DEATH (revised: the incident is known) with by = trap for a citizen
M.on['EV:DEATH'] = function(K, ev)
  local d = type(ev.d) == 'table' and ev.d or {}
  local u = int(d.unit)
  if not st or d.by ~= 'trap' or not u or not (d.citizen == 1 or d.citizen == true) then return end
  st.kills = st.kills or {}
  for _, k in ipairs(st.kills) do if k.u == u then return end end
  local now = int(ev.tick) or K.now().tick
  local pos = type(d.pos) == 'table' and d.pos or {}
  st.kills[#st.kills + 1] = {u = u, t = now, x = int(pos[1]), y = int(pos[2]), z = int(pos[3]), th = int(d.thirst), hu = int(d.hunger)}
  while #st.kills > M.KILL_KEEP do table.remove(st.kills, 1) end
  local n = M.kills(now)
  local at = pos[1] and string.format('%d,%d,%d', pos[1], pos[2], pos[3]) or '?'
  K.log('warn', 'traps: citizen %d killed by our own trap at %s (thirst %s, hunger %s): %d within a year', u, at,
        tostring(d.thirst), tostring(d.hunger), n)
  if not st.dt or now - st.dt >= M.DAY then
    st.dt = now
    local q = string.format('%d killed by our own traps in a year (latest %d at %s, thirst %s): stone-fall traps hit citizens, only ' ..
                            'cage traps pass them; drink and food inside first, no new stone-fall traps (hall, bridge lanes)',
                            n, u, at, tostring(d.thirst))
    K.emit('DECISION_NEEDED', 'A', ('trap_friendly: ' .. q):sub(1, 200),
           {id = 'trap_friendly', q = q:sub(1, 200), n = n, unit = u, pos = pos,
            cmds = {'dfllm cmd inspect what=reach', 'dfllm cmd inspect what=water_sources', 'dfllm plan propose y.json'},
            opts = {'drink inside', 'no new stone-fall traps', 'B1 up'}})
  end
  save(K)
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.traps')
  p = type(p) == 'table' and p or {}
  st = {v = 2, ot = int(p.ot), oid = int(p.oid), on = int(p.on), dt = int(p.dt), kills = type(p.kills) == 'table' and p.kills or nil}
  pub, last = nil, nil
end

function M.step(K)
  local now = K.now().tick
  local c = conf(K)
  local man = K.manifest()
  local entries = type(man.traps) == 'table' and man.traps or {}
  local idx, ids = M.read()
  local busy = M.full(K, ids)
  local r = M.tally(entries, idx)
  local hall = false
  for _, e in ipairs(entries) do if type(e) == 'table' and e.id == 'Z2' then hall = true end end
  local z2 = type(man.zones) == 'table' and type(man.zones.Z2) == 'table' and man.zones.Z2 or nil
  if not hall and z2 and #z2 > 0 then             -- a hall built before the Z2 entry: its built traps count as listed
    local ok, n, armed = K.call('snapshot', 'traps', z2)
    if ok and int(n) and int(armed) then
      r.m, r.b, r.n = r.m + int(n), r.b + int(n), r.n + int(armed)
    end
  end
  r.c = M.free_cages(busy)
  last = r
  if r.m == 0 then pub = nil; return end
  local ord = order_cages(K, c, r, now)
  local ck = M.kills(now)
  pub = {n = r.n, m = r.m, b = r.b, w = r.w, wn = r.wn, f = r.f, c = r.c, l = r.l, lh = r.lh, ord = ord, ck = ck > 0 and ck or nil}
end

function M.state() return pub and {traps = pub} or {} end

-- public: the listed trap tiles without a trap building (destroyed or never built): each needs a mechanism again
-- (economy's supply pass may count them; the CLI's `traps at=ways|hall` places them)
function M.need() return last and last.l or 0 end

-- public (tests, inspect): the last tally
function M.last() return last end

return M
