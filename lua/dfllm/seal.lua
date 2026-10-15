-- seal (FR-22/24/33/37/54/56/57, FR-59/60/62/63): reachability, the seal against the map edge, the perimeter and the
-- civ-alert refuge, from walk groups and revealed tiles only. Fair play (CONTRACTS §1.4): a tile is read only after
-- `designation.hidden` was checked; walk groups (dfhack.maps.getWalkableGroup, DF's own job-feasibility cache)
-- are read for revealed tiles only; units only by census id. Group ids change over time, so every check
-- compares against the groups the citizens stand on now, never a stored id.
--   reach     (FR-22) walkable groups of citizens, food, drink, seeds, beds, farm plots, wells, depot and the map
--             edge; every class off the main citizen group is flagged, so is every STAIR_UP/STAIR_DOWN without its
--             counterpart (FR-63: each flagged stair is read again before it is reported). CUTOFF (A) when citizens
--             lose the group of their food, drink or beds, with the tile that did it. Runs periodically, before a
--             closing construction is queued (runner.apply -> seal.closing) and after every change of constructions,
--             doors, hatches and bridges (a cheap re-check of the known positions first, the full audit only when it
--             looks worse)
--   items     (FR-59/62) the item census behind reach and refuge: drink, food and seeds per tile, once per stack unit,
--             stored ones (barrels, bins, bags, pots) included; carried or worn ones (a unit holds the item or its
--             container) and those in a forbidden container are not. It runs on its own cadence and is skipped while
--             the item vectors keep their sizes, so an audit reads stock tiles, never the items
--   seal      (FR-54) walk groups of the map-edge tiles against the citizens' groups ("seal verified: no route");
--             otherwise a sliced search from the citizens over revealed walkable tiles (a BFS over the interior, an
--             A* outside to the nearest map-edge tile): the first leak (tile, building, door/bridge state) and the
--             openings of the interior (independent routes). After every siege and lever pull; SEAL_LEAK (A) when
--             the gates are up and a route remains. In PEACE the gates stand open (D-14): the search runs there only
--             when its answer can change
--   perimeter (FR-56/60) walls, doors, gates and killbox tiles of defense projects, of the manifest and of the
--             inside/outside boundary (learned by the BFS in PEACE), plus (FR-60, forts without a manifest) every
--             wall, door, gate or bridge around an opening the entrance check finds sealed, and on the verb
--             perimeter.record the closers on the boundary of the citizens' group; persisted in m.seal. After a
--             siege they are compared with the map, lost pieces re-queued (runner.repair) and PERIMETER_BROKEN (A)
--             raised; a piece already gone in PEACE or when a siege begins is retired, never rebuilt
--   defense   (FR-24) every bridge's real gate_flags, the walk groups on its sides and its levers' links
--   refuge    (FR-33/37/57) burrow audits (tiles, citizens inside, drink, food, beds) and alert_burrow(mode): the
--             civ-alert burrow siege uses. Kern+ normally, the refuge (Tiefe+) in BREACH and until CFG.back_days
--             quiet days, never a burrow without drink, food and beds for the population: the fallback is the
--             interior burrow (CFG.interior, painted from revealed walkable inside tiles of the citizens' group),
--             else no confinement at all; REFUGE_FAIL (A) says so
-- Cost (FR-62): work runs in coroutines; a work unit is about one DF read (tile flags, walk group, tiletype, burrow
-- test, the fields of one item). A token bucket refilled in real time caps the units per second (CFG.rate, or
-- CFG.rate_urgent while an urgent job runs: a lever pull, a siege, a CUTOFF re-check, perimeter.record, the first
-- result after a load) and CFG.work caps one frame; an urgent job pre-empts a background one, which resumes later.
-- The map edge keeps one tile per walkable run, the stairs and interior come from a flood over the citizens' groups
-- (not a box over hidden rock), burrow sizes are cached and a periodic audit with unchanged inputs is skipped.
local CAD = require('dfllm.util.cadence')   -- BUG-008: a standing class-A condition is announced again only with news
local M = {name = 'seal', every = {ticks = 50}, verbs = {}, on = {}, inspect = {}}

local DAY = 1200
M.CFG = {
  -- FR-62 (live Run 9: 37 ms/s with 800 units per frame and no cap per second on a 5-citizen fort, 402 units, 18.7k
  -- items): a work unit is about one DF read, roughly 0.3-0.8 us live. Background jobs get at most CFG.rate units a
  -- second (about 2-5 ms/s at the peak, less than half of that on average on a fort that size: test_seal_run9.lua);
  -- urgent ones CFG.rate_urgent until they are done
  work = 800,                 -- most work units in one frame
  rate = 6000,                -- work units per real second for background jobs ...
  rate_urgent = 24000,        -- ... and while an urgent job runs
  min_slice = 200,            -- a background job waits for the next regular step when the bucket holds less
  audit_every = 3 * DAY,      -- full reach + refuge audit in PEACE ...
  audit_alert = DAY,          -- ... and in the other modes
  audit_max_age = 9 * DAY,    -- a periodic audit whose inputs did not change is skipped up to this age
  items_every = 7 * DAY,      -- item census in PEACE ...
  items_alert = DAY,          -- ... and in the other modes
  items_stale = 21 * DAY,     -- a periodic census with unchanged item vector sizes is skipped up to this age
  pos_max = 4000,             -- stock tiles one census keeps (in ITEM_CATS order: drink first)
  reps_per = 4, reps_max = 48,   -- quick re-check tiles: the biggest stacks per class and walk group
  quick_every = 100,          -- fingerprint poll (constructions, doors, hatches, bridges)
  quick_min = 300,            -- ticks between two re-checks it triggers
  seal_every = 7 * DAY,       -- periodic entrance check (walk groups) ...
  bfs_every = 28 * DAY,       -- ... and its BFS in PEACE while the open gates leak by design and nothing changed
  edges_every = 28 * DAY,     -- map-edge scan
  edge_run = 64,              -- one edge tile per walkable run along the border, and one more per this many tiles
  scan_every = 14 * DAY,      -- flood over the citizens' groups: stairs without counterpart, interior tiles
  scan_min = 3 * DAY,         -- a scan a finished project asks for waits at least this long after the last one
  bsize_stale = 7 * DAY,      -- a burrow's tile count is kept this long while its block count is unchanged
  lever_delay = 40,           -- ticks after a bridge moved before the entrance check (walk groups settle)
  bfs_max = 60000,            -- tiles the entrance BFS may visit
  blame_max = 4000,           -- tiles the CUTOFF blame search may visit
  scan_max = 60000,           -- tiles the scan flood may visit
  edges_max = 8000, edges_keep = 2000, entries_max = 400, routes_max = 8, pend_max = 2000, stairs_max = 40,
  rec_r = 1,                  -- FR-60: closers this far around a sealed opening's inside and outside tile
  pred_near = 25,             -- FR-33: a wild large predator counts only this close to an entrance (sense)
  back_days = 3,              -- FR-57: the refuge stays the confinement until this many days without a hostile
  min_tiles = 20, drink_per_cit = 1, food_per_cit = 1, bed_pct = 25,   -- FR-37 burrow audit (per citizen)
  interior = 'Innen+',        -- the whole-interior burrow, painted when Kern+ fails its audit
  paint_chunk = 400, interior_max = 20000, repaint = 7 * DAY,
  perim_max = 1500, requeue_cool = 7 * DAY,
}
local CFG = M.CFG

local ITEM_CATS = {'DRINK', 'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH', 'SEEDS'}
local ITEM_CLS = {DRINK = 'drink', SEEDS = 'seeds'}                    -- everything else: food
local STOCK = {'drink', 'food', 'seeds'}                                -- census counts per tile, in this order
local CI = {drink = 1, food = 2, seeds = 3}
-- FR-59: the item itself. No 'in_inventory': every drink in a barrel carries it; carried items are found by holder
local SKIP = {'forbid', 'trader', 'removed', 'garbage_collect', 'construction', 'dump', 'hostile', 'in_building',
              'rotten'}
-- a container up the chain (barrel, bin, bag, pot): a forbidden one holds nobody's drink (FR-50); part of a building
-- (a placed chest) is fine
local CSKIP = {'forbid', 'trader', 'removed', 'garbage_collect', 'construction', 'dump', 'hostile', 'rotten'}
local BLD_CATS = {{'BED', 'bed'}, {'FARM_PLOT', 'farm'}, {'WELL', 'well'}, {'TRADE_DEPOT', 'depot'}}
local CLASSES = {'food', 'drink', 'seeds', 'bed', 'farm', 'well', 'depot', 'exit'}
local VITAL = {'food', 'drink', 'bed'}
-- quickfort build keys that can close a path (dfpilot/bp/validate.py BUILD_KEYS, primitives.BRIDGE_KEYS)
local CLOSERS = {Cw = 'wall', CW = 'wall', CF = 'fort', d = 'door', H = 'hatch', x = 'floodgate', W = 'grate',
                 B = 'bars', s = 'statue', gw = 'bridge', gd = 'bridge', gx = 'bridge', ga = 'bridge', gs = 'bridge'}
local QF_OF = {wall = 'Cw', fort = 'CF', door = 'd', hatch = 'H', floodgate = 'x', grate = 'W', bars = 'B'}
local BKIND = {Door = 'door', Hatch = 'hatch', Bridge = 'bridge', Floodgate = 'floodgate', GrateWall = 'grate',
               BarsVertical = 'bars', Statue = 'statue'}
-- FR-60: what a perimeter piece can be (every closer but a statue)
local REC = {wall = true, fort = true, door = true, hatch = true, floodgate = true, grate = true, bars = true,
             bridge = true}
local GATED = {ALERT = true, SIEGE = true, BREACH = true, DRILL = true, RECOVERY = true}   -- gate raises on purpose

local st      -- persisted m.seal
local mem     -- runtime: caches, results, jobs
local dirty
local due     -- due(name, tick, why, arg): schedule a job (scheduling section)

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function now_t(K) return K.now().tick end
local function save(K) if dirty then K.persist.set('m.seal', st); dirty = false end end
local function trunc(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end

-- tile keys: x, y < 4096 and z < 4096 (DF maps are far smaller)
local function key3(x, y, z) return (z * 4096 + y) * 4096 + x end
local function dec3(k) return k % 4096, (k // 4096) % 4096, k // 16777216 end
local function kstr(x, y, z) return string.format('%d,%d,%d', x, y, z) end

local function sorted_keys(t)
  local r = {}
  for k in pairs(t or {}) do r[#r + 1] = k end
  table.sort(r, function(a, b) return tostring(a) < tostring(b) end)
  return r
end

---------------------------------------------------------------- work slicing
-- a job is a coroutine; spend() yields once the frame's work is used up. Outside a coroutine (a synchronous
-- inspect) nothing yields.
local function spend(n)
  mem.left = mem.left - (n or 1)
  if mem.left <= 0 and coroutine.isyieldable() then coroutine.yield() end
end

---------------------------------------------------------------- tile reads (revealed only)
local P = {x = 0, y = 0, z = 0}

-- designation, occupancy of a revealed tile; nil for hidden or off-map tiles
local function rev(x, y, z)
  local des, occ = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return nil end
  return des, occ
end

-- walk group of a revealed tile: nil = hidden/off-map, 0 = not walkable
local function grp(x, y, z)
  local des = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return nil end
  P.x, P.y, P.z = x, y, z
  return dfhack.maps.getWalkableGroup(P) or 0
end

-- {shape = name, mat = name} of a tile's tiletype (callers checked that it is revealed)
local function shape(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  if tt == nil then return nil end
  local c = mem.tt[tt]
  if c == nil then
    c = false
    pcall(function()
      local a = df.tiletype.attrs[tt]
      c = {shape = df.tiletype_shape[a.shape], mat = df.tiletype_material[a.material]}
    end)
    mem.tt[tt] = c
  end
  return c or nil
end

local function map_size()
  local ok, x, y, z = pcall(dfhack.maps.getTileSize)
  if ok and x then return x, y, z end
  local bx, by, bz = dfhack.maps.getSize()
  return bx * 16, by * 16, bz
end

local UP = {STAIR_UP = true, STAIR_UPDOWN = true}
local DOWN = {STAIR_DOWN = true, STAIR_UPDOWN = true}
local STAIR_KIND = {STAIR_UP = 'up stair', STAIR_DOWN = 'down stair', STAIR_UPDOWN = 'up/down stair'}

---------------------------------------------------------------- buildings
local function bld_at(x, y, z)
  local ok, b = pcall(dfhack.buildings.findAtTile, x, y, z)       -- Lua API.txt:2484
  return ok and b or nil
end
local function btype(b)
  local ok, n = pcall(function() return df.building_type[b:getType()] end)
  return ok and n or nil
end
local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return ok and r == true
end
local function gflag(b, k)
  local ok, v = pcall(function() return b.gate_flags[k] end)
  if ok then return v end
end
local function dflag(b, k)
  local ok, v = pcall(function() return b.door_flags[k] end)
  if ok then return v end
end
-- bridge gate_flags are raised/raising/lowering (lever.lua:39-41), doors use door_flags
local function bstate(b)
  local t = btype(b) or '?'
  if t == 'Door' or t == 'Hatch' then
    return t, dflag(b, 'forbidden') and 'locked' or (dflag(b, 'closed') and 'closed' or 'open')
  elseif t == 'Bridge' then
    if gflag(b, 'raising') or gflag(b, 'lowering') then return t, 'moving' end
    local up = gflag(b, 'raised')
    if up == nil then up = gflag(b, 'closed') end
    if up == nil then return t, 'unknown' end
    return t, up and 'up' or 'down'
  elseif t == 'Floodgate' or t == 'GrateWall' or t == 'BarsVertical' then
    return t, gflag(b, 'closed') and 'closed' or 'open'
  end
  return t, built(b) and 'built' or 'planned'
end

-- the building on a revealed tile with a building occupancy (findAtTile is a linear scan: tiles without one skip it)
local function bld_on(x, y, z, occ)
  if occ then
    local ok, v = pcall(function() return occ.building end)
    if ok and (v == 0 or v == nil or v == false) then return nil end
  end
  return bld_at(x, y, z)
end

local function vec(name, sub)
  local ok, v = pcall(function() return df.global.world[name].other[sub] end)
  return ok and v or nil
end
local function vlen(v) return v and #v or 0 end

-- the bridge building covering (x, y, z): findAtTile first, else by extents (a raised bridge need not show)
local function bridge_at(fp)
  local x, y, z = fp[1], fp[2], fp[3]
  local b = bld_at(x, y, z)
  if b and btype(b) == 'Bridge' then return b end
  local bv = vec('buildings', 'BRIDGE')
  for i = 0, vlen(bv) - 1 do
    local c = bv[i]
    if c and c.z == z and c.x1 <= fp[4] and c.x2 >= x and c.y1 <= fp[5] and c.y2 >= y then return c end
  end
end

---------------------------------------------------------------- citizens (by census id, CONTRACTS §1.4)
local function citizens(K)
  local cu = K.census.u
  local list = {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    if u then
      local x, y, z = dfhack.units.getPosition(u)
      if x then
        local g = grp(x, y, z)
        if g and g ~= 0 then list[#list + 1] = {id = id, x = x, y = y, z = z, g = g} end
      end
    end
  end
  return list
end

local function group_counts(cits)
  local by, main, best = {}, nil, 0
  for _, c in ipairs(cits) do by[c.g] = (by[c.g] or 0) + 1 end
  for _, g in ipairs(sorted_keys(by)) do
    if by[g] > best then main, best = g, by[g] end
  end
  return by, main
end

---------------------------------------------------------------- items (FR-59)
local function item_pos(it)
  local a, b, c = dfhack.items.getPosition(it)                    -- Lua API.txt:2055 (a container's for stored items)
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end
local function flagged(f, list)
  for _, k in ipairs(list) do if f[k] then return true end end
  return false
end
-- stock a citizen can use: not skipped itself, not carried or worn (in_inventory with a unit holder), and every
-- container up the chain usable and not carried either (as economy's FR-50 rule: a forbidden barrel, bin or bag, or
-- the one around it, holds nobody's drink, food or seeds). Returns ok and the containers read (work units)
local function usable_(it)
  if flagged(it.flags, SKIP) then return false, 0 end
  local cur, n = it, 0
  while n < 4 do
    if not cur.flags.in_inventory then return true, n end          -- on the ground: a stockpile, a floor
    local hu = dfhack.items.getHolderUnit                          -- Lua API.txt items.getHolderUnit
    if hu and hu(cur) then return false, n end                     -- carried or worn: nobody else's
    local cont = dfhack.items.getContainer(cur)                    -- Lua API.txt:2035
    if not cont then
      local hb = dfhack.items.getHolderBuilding
      return hb == nil or hb(cur) ~= nil, n                        -- stored in a building, not held by a unit
    end
    if flagged(cont.flags, CSKIP) then return false, n end
    cur, n = cont, n + 1
  end
  return false, n
end
local function usable(it)
  local ok, v, n = pcall(usable_, it)
  if ok then return v == true, n or 0 end
  return false, 0
end
local function stack(it) return int(it.stack_size) or 1 end

local function items_sig()
  local p = {}
  for i, cat in ipairs(ITEM_CATS) do p[i] = vlen(vec('items', cat)) end
  return table.concat(p, ',')
end

-- FR-59/62: drink, food and seeds per tile (stored ones included), once per stack unit. An audit reads these tiles
-- (walk group, burrows) instead of the items. A periodic census whose item vectors kept their sizes is skipped up
-- to CFG.items_stale (nothing to read). `inline`: the audit's first census, it schedules no audit itself.
local function job_items(K, why, inline)
  local t0 = now_t(K)
  local sig = items_sig()
  spend(#ITEM_CATS)
  local I = mem.items
  if I and why == 'periodic' and I.sig == sig and t0 - I.tick < CFG.items_stale then
    I.seen = t0
    mem.stats.items_skip = (mem.stats.items_skip or 0) + 1
    return
  end
  local at, keys, tot, drop, nread = {}, {}, {0, 0, 0}, {0, 0, 0}, 0
  for _, cat in ipairs(ITEM_CATS) do
    local ci = CI[ITEM_CLS[cat] or 'food']
    local i = 0
    while true do
      local v = vec('items', cat)                       -- re-read after every yield
      if not v or i >= #v then break end
      local it = v[i]
      i = i + 1
      local cost = 2
      if it then
        local ok, nc = usable(it)
        cost = cost + 2 * nc
        if ok then
          local x, y, z = item_pos(it)
          cost = cost + 1
          if x and x >= 0 then
            local n = stack(it)
            local k = key3(x, y, z)
            local c = at[k]
            if not c and #keys < CFG.pos_max then c = {0, 0, 0}; at[k] = c; keys[#keys + 1] = k end
            if c then c[ci], tot[ci] = c[ci] + n, tot[ci] + n
            else drop[ci] = drop[ci] + n end
          end
        end
      end
      nread = nread + 1
      spend(cost)
    end
  end
  mem.items = {tick = t0, seen = t0, sig = sig, at = at, keys = keys, tot = tot, drop = drop, n = nread}
  if not inline then due('audit', t0, 'items') end
end

---------------------------------------------------------------- burrows
local function burrow(name)
  local ok, b = pcall(dfhack.burrows.findByName, name)            -- Lua API.txt:2412
  return ok and b or nil
end

local function burrow_names(K)
  local man = K.manifest()
  local kern, refuge
  for _, name in ipairs(sorted_keys(man.burrows)) do
    local b = man.burrows[name]
    local role = type(b) == 'table' and b.role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  if not refuge and burrow('Refuge') then refuge = 'Refuge' end      -- FR-57's name for it
  return kern or 'Kern+', refuge or 'Tiefe+'
end

local function block_list(name)
  local b = burrow(name)
  if not b then return nil end
  local ok, blocks = pcall(dfhack.burrows.listBlocks, b)
  return ok and type(blocks) == 'table' and blocks or nil
end

-- tiles of a burrow (burrows screen count): blocks x 256 tiles, sliced. FR-62: kept while the block count is
-- unchanged, up to CFG.bsize_stale (seal's own painting forgets it)
local function burrow_size(name, t)
  local blocks = block_list(name)
  spend(1)
  if not blocks then return 0 end
  local c = mem.bsize[name]
  if c and c.nb == #blocks and t - c.t < CFG.bsize_stale then return c.n end
  local n = 0
  for i = 1, #blocks do
    local b = burrow(name)                                         -- never keep a DF pointer across frames
    local blk = b and blocks[i]
    if not blk then break end
    spend(1)
    for x = 0, 15 do
      for y = 0, 15 do
        if dfhack.burrows.isAssignedBlockTile(b, blk, x, y) then n = n + 1 end
      end
      spend(16)
    end
  end
  mem.bsize[name] = {nb = #blocks, n = n, t = t}
  return n
end

local function in_burrow(b, x, y, z)
  P.x, P.y, P.z = x, y, z
  local ok, v = pcall(dfhack.burrows.isAssignedTile, b, P)
  return ok and v == true
end

---------------------------------------------------------------- scheduling
-- priority among urgent jobs, then among background ones
local ORDER = {'perim', 'seal', 'quick', 'audit', 'items', 'scan', 'paint', 'edges'}

-- one pending run per job: the earliest tick and the strongest reason (an event beats 'periodic'/'retire', a
-- post-siege diff beats everything), so no request is lost
local WEAK = {periodic = true, retire = true, boot = true}
due = function(name, tick, why, arg)
  why = why or ''
  local d = mem.due[name]
  if not d then mem.due[name] = {tick = tick, why = why, arg = arg}; return end
  if tick < d.tick then d.tick = tick end
  if why == 'post' or (WEAK[d.why] and not WEAK[why] and d.why ~= 'post') then d.why = why end
  if arg ~= nil and d.arg == nil then d.arg = arg end
end

local function quiet(K)
  local last = st.hostile or -1
  if last < 0 then return math.huge end
  return now_t(K) - last
end

---------------------------------------------------------------- reach audit (FR-22) + burrow audit (FR-37)
local function add(t, g, n) t[g] = (t[g] or 0) + n end

-- the walk group a building stands on: its centre tile, else the first walkable neighbour (wells, depots)
local function bgroup(b)
  local x, y, z = b.centerx, b.centery, b.z
  if not (x and y and z) then return nil end
  local g = grp(x, y, z)
  if g and g ~= 0 then return g, x, y, z end
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local h = grp(x + dx, y + dy, z)
        if h and h ~= 0 then return h, x + dx, y + dy, z end
      end
    end
  end
end

local function burrow_audit(K, ncit, a)
  local need = {tiles = math.max(CFG.min_tiles, ncit), drink = ncit * CFG.drink_per_cit,
                food = ncit * CFG.food_per_cit, beds = math.max(1, (ncit * CFG.bed_pct + 99) // 100)}
  local why = {}
  if not a.exists then why[1] = 'missing'
  else
    if a.tiles < need.tiles then why[#why + 1] = string.format('%d tiles<%d', a.tiles, need.tiles) end
    if a.drink < need.drink and a.wells == 0 then why[#why + 1] = string.format('drink %d<%d', a.drink, need.drink) end
    if a.food < need.food then why[#why + 1] = string.format('food %d<%d', a.food, need.food) end
    if a.beds < need.beds then why[#why + 1] = string.format('beds %d<%d', a.beds, need.beds) end
  end
  a.ok = #why == 0
  a.why = table.concat(why, ', ')
  return a
end

local function audit_names(K)
  local kern, refuge = burrow_names(K)
  local names = {kern}
  if refuge ~= kern then names[#names + 1] = refuge end
  if CFG.interior ~= kern and CFG.interior ~= refuge then names[#names + 1] = CFG.interior end
  return names, kern, refuge
end

-- one pass over citizens, the census's stock tiles, beds, farm plots, wells, depots and the edge tiles: walk groups
-- per class (reach) and per-burrow counts (refuge). Pure until the end: the caller commits the result.
local function audit_pass(K)
  local t0 = now_t(K)
  local cits = citizens(K)
  spend(3 * #cits)
  local cg, main = group_counts(cits)
  local R = {tick = t0, main = main, cit = {n = #cits, by = cg}, cls = {}, reps = {}}
  for _, c in ipairs(CLASSES) do R.cls[c] = {n = 0, by = {}, at = {}} end
  local names, kern, refuge = audit_names(K)
  local B = {}
  for _, n in ipairs(names) do
    B[n] = {exists = burrow(n) ~= nil, tiles = 0, inside = 0, drink = 0, food = 0, beds = 0, wells = 0}
  end
  for _, n in ipairs(names) do
    if B[n].exists then
      local b = burrow(n)
      for _, c in ipairs(cits) do if in_burrow(b, c.x, c.y, c.z) then B[n].inside = B[n].inside + 1 end end
    end
  end
  spend(#cits * #names)
  -- the quick re-check tiles: the biggest stacks per class and walk group
  local best = {food = {}, drink = {}, bed = {}}
  local function rep(cls, g, n, x, y, z)
    local per = best[cls]
    if not per then return end
    local l = per[g]
    if not l then l = {}; per[g] = l end
    if #l < CFG.reps_per then l[#l + 1] = {n, x, y, z}; return end
    local lo = 1
    for j = 2, #l do if l[j][1] < l[lo][1] then lo = j end end
    if n > l[lo][1] then l[lo] = {n, x, y, z} end
  end
  local function burrows_at(x, y, z)
    local r = {}
    for _, bn in ipairs(names) do
      local b = B[bn].exists and burrow(bn)
      r[bn] = b and in_burrow(b, x, y, z) or false
    end
    return r
  end
  -- FR-59/62: stock per tile from the census (stored drink, food and seeds included); one group read per tile
  if not mem.items then job_items(K, 'audit', true) end
  local I = mem.items
  R.items = {tick = I.tick, n = I.n, tiles = #I.keys, drop = {drink = I.drop[1], food = I.drop[2], seeds = I.drop[3]}}
  for _, k in ipairs(I.keys) do
    local c = I.at[k]
    local x, y, z = dec3(k)
    local g = grp(x, y, z)
    local cost = 2
    if g and g ~= 0 then
      local inb
      for ci, cls in ipairs(STOCK) do
        local n = c[ci]
        if n > 0 then
          local C = R.cls[cls]
          C.n = C.n + n
          add(C.by, g, n)
          if not C.at[g] then C.at[g] = {x, y, z} end
          rep(cls, g, n, x, y, z)
          if cls ~= 'seeds' then
            if not inb then inb = burrows_at(x, y, z); cost = cost + 2 * #names end
            for _, bn in ipairs(names) do if inb[bn] then B[bn][cls] = B[bn][cls] + n end end
          end
        end
      end
    end
    spend(cost)
  end
  for _, e in ipairs(BLD_CATS) do
    local i = 0
    while true do
      local v = vec('buildings', e[1])                -- re-read after every yield
      if not v or i >= #v then break end
      local b = v[i]
      i = i + 1
      local cost = 2
      if b and built(b) then
        local g, x, y, z = bgroup(b)
        cost = cost + 2
        if g then
          local C = R.cls[e[2]]
          C.n = C.n + 1
          add(C.by, g, 1)
          if not C.at[g] then C.at[g] = {x, y, z} end
          rep(e[2], g, 1, x, y, z)
          if e[2] == 'bed' or e[2] == 'well' then
            local fld = e[2] == 'bed' and 'beds' or 'wells'
            local inb = burrows_at(b.centerx, b.centery, b.z)
            cost = cost + 2 * #names
            for _, bn in ipairs(names) do if inb[bn] then B[bn][fld] = B[bn][fld] + 1 end end
          end
        end
      end
      spend(cost)
    end
  end
  R.edge_known = mem.edges ~= nil
  for _, k in ipairs(mem.edges and mem.edges.list or {}) do
    local x, y, z = dec3(k)
    local g = grp(x, y, z)
    if g and g ~= 0 then
      local C = R.cls.exit
      C.n = C.n + 1
      add(C.by, g, 1)
      if not C.at[g] then C.at[g] = {x, y, z} end
    end
    spend(2)
  end
  for _, n in ipairs(names) do
    if B[n].exists then B[n].tiles = burrow_size(n, t0) end
    burrow_audit(K, #cits, B[n])
  end
  for cls, per in pairs(best) do
    local out = {}
    for _, g in ipairs(sorted_keys(per)) do
      for _, r in ipairs(per[g]) do
        if #out < CFG.reps_max then out[#out + 1] = {r[2], r[3], r[4]} end
      end
    end
    R.reps[cls] = out
  end
  R.burrows, R.names = B, {kern = kern, refuge = refuge, interior = CFG.interior}
  return R, cits
end

-- citizens on a group without any of a vital class that exists somewhere
local function cut_of(cg, by_cls, totals)
  local cut = {}
  for _, cls in ipairs(VITAL) do
    local n = 0
    if (totals[cls] or 0) > 0 then
      for g, k in pairs(cg) do if not by_cls[cls][g] then n = n + k end end
    end
    cut[cls] = n
  end
  return cut
end

---------------------------------------------------------------- stairs without counterpart (FR-63)
-- a STAIR_UP needs a STAIR_DOWN or STAIR_UPDOWN above, a STAIR_DOWN a STAIR_UP or STAIR_UPDOWN below; an up/down stair
-- is flagged only when neither way works. Revealed tiles only: a hidden counterpart is 'unrevealed', never read.
-- Returns kind, why, or nil when the tile is no stair or has its counterpart.
local function stair_dead(x, y, z, sh)
  if not sh then
    if not rev(x, y, z) then return nil end
    local s = shape(x, y, z)
    sh = s and s.shape
  end
  if not (sh and STAIR_KIND[sh]) then return nil end
  local up_bad, down_bad
  if UP[sh] then
    local a = rev(x, y, z + 1) and shape(x, y, z + 1)
    if not a then up_bad = 'above unrevealed' elseif not DOWN[a.shape] then up_bad = 'no stair above' end
  end
  if DOWN[sh] then
    local c = rev(x, y, z - 1) and shape(x, y, z - 1)
    if not c then down_bad = 'below unrevealed' elseif not UP[c.shape] then down_bad = 'no stair below' end
  end
  local why
  if sh == 'STAIR_UP' then why = up_bad
  elseif sh == 'STAIR_DOWN' then why = down_bad
  elseif up_bad and down_bad then why = up_bad .. ', ' .. down_bad end
  if why then return STAIR_KIND[sh], why end
end

-- live Run 9: 'down stair at 30,66,109' was flagged from a scan days old while z108..80 below it had been dug to
-- stairs since. Every flagged stair is read again (the tile and its counterpart) before it is reported; the fixed
-- ones are dropped from the scan result.
local function live_stairs()
  local S = mem.scan
  if not S or #S.stairs == 0 then return {} end
  local keep = {}
  for _, s in ipairs(S.stairs) do
    local kind, why = stair_dead(s[1], s[2], s[3])
    if kind then keep[#keep + 1] = {s[1], s[2], s[3], kind, why, grp(s[1], s[2], s[3]) or 0} end
    spend(6)
  end
  S.stairs = keep
  return keep
end

local function stairs_flag(dead)
  local s = dead[1]
  if not s then return nil end
  return string.format('stairs: %d without counterpart (%s at %d,%d,%d)', #dead, s[4], s[1], s[2], s[3])
end

-- the class flags of an audit, then the stairs flag read now
local function reach_flags(R, dead)
  local f = {}
  local main = R.main
  local off = R.cit.n - (main and R.cit.by[main] or 0)
  if off > 0 then f[#f + 1] = string.format('citizens: %d of %d off the main group', off, R.cit.n) end
  for _, cls in ipairs(CLASSES) do
    local C = R.cls[cls]
    local on = main and C.by[main] or 0
    if cls == 'exit' then
      if R.edge_known and on == 0 then f[#f + 1] = 'exit: no map edge on the citizens\' group (sealed)' end
    elseif C.n > 0 and on == 0 then
      f[#f + 1] = cls .. ': none on the citizens\' group'
    elseif C.n > on then
      f[#f + 1] = string.format('%s: %d of %d off-group', cls, C.n - on, C.n)
    end
  end
  local sf = stairs_flag(dead)
  if sf then f[#f + 1] = sf end
  return f
end

---------------------------------------------------------------- CUTOFF blame
-- a closing tile: constructed wall/fortification, or a door/hatch/bridge/floodgate/grate/bars/statue building;
-- the kind and the building
local function closer_at(x, y, z)
  local des, occ = rev(x, y, z)
  if not des then return nil end
  local s = shape(x, y, z)
  if s and (s.shape == 'WALL' or s.shape == 'FORTIFICATION') and s.mat == 'CONSTRUCTION' then
    return s.shape == 'WALL' and 'wall' or 'fort'
  end
  local b = bld_on(x, y, z, occ)
  if b then return BKIND[btype(b) or ''], b end
end
local function closer_kind(x, y, z) return (closer_at(x, y, z)) end

-- groups around a tile (8 on the level, the tiles above and below)
local function around(x, y, z, out)
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local g = grp(x + dx, y + dy, z)
        if g and g ~= 0 then out[g] = true end
      end
    end
  end
  for _, dz in ipairs({-1, 1}) do
    local g = grp(x, y, z + dz)
    if g and g ~= 0 then out[g] = true end
  end
  return out
end

local function separates(x, y, z, gc, has)
  local s = around(x, y, z, {})
  if not s[gc] then return false end
  for g in pairs(s) do if g ~= gc and has[g] then return true end end
  return false
end

local function ring_separates(fp, gc, has)
  local s = {}
  for x = fp[1] - 1, fp[4] + 1 do
    for y = fp[2] - 1, fp[5] + 1 do
      if x < fp[1] or x > fp[4] or y < fp[2] or y > fp[5] then
        local g = grp(x, y, fp[3])
        if g and g ~= 0 then s[g] = true end
      end
    end
  end
  if not s[gc] then return false end
  for g in pairs(s) do if g ~= gc and has[g] then return true end end
  return false
end

-- neighbours a walker may step to from (x,y,z) (DF moves: 8 on the level, stairs, up a ramp), as keys; the caller
-- filters them by walk group, so an over-approximation never connects two groups (down a ramp: see bfs). `sh` = the
-- tile's shape when the caller read it already.
local function steps(x, y, z, out, sh)
  local n = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then n = n + 1; out[n] = key3(x + dx, y + dy, z) end
    end
  end
  if sh == nil then
    local s = shape(x, y, z)
    sh = s and s.shape
  end
  if sh and UP[sh] then
    local a = rev(x, y, z + 1) and shape(x, y, z + 1)
    if a and DOWN[a.shape] then n = n + 1; out[n] = key3(x, y, z + 1) end
  end
  if sh and DOWN[sh] then
    local b = rev(x, y, z - 1) and shape(x, y, z - 1)
    if b and UP[b.shape] then n = n + 1; out[n] = key3(x, y, z - 1) end
  end
  if sh == 'RAMP' then
    for dy = -1, 1 do
      for dx = -1, 1 do
        if dx ~= 0 or dy ~= 0 then n = n + 1; out[n] = key3(x + dx, y + dy, z + 1) end
      end
    end
  end
  return n
end

-- the open top of a ramp one level down (a walker steps down the ramp from here)
local function ramp_top(k)
  local x, y, z = dec3(k)
  if z < 1 or not rev(x, y, z) then return false end
  local s = shape(x, y, z)
  return s ~= nil and s.shape == 'RAMP_TOP'
end

-- the tile that cut citizens on group gc from a class held by the groups in `has`
local function blame(K, gc, has, cut_pos)
  for _, k in ipairs(mem.fresh) do                       -- closers completed since the last audit, newest first
    local x, y, z = dec3(k)
    local p = mem.done_info[k] or {}
    if separates(x, y, z, gc, has) then return {x, y, z, p.kind or closer_kind(x, y, z) or '?', p.proj} end
    spend(20)
  end
  local i = 0
  while true do
    local bv = vec('buildings', 'BRIDGE')                 -- re-read after every yield
    if not bv or i >= #bv then break end
    local b = bv[i]
    i = i + 1
    if b then
      local _, s = bstate(b)
      if s == 'up' and ring_separates({b.x1, b.y1, b.z, b.x2, b.y2, b.z}, gc, has) then
        return {b.centerx, b.centery, b.z, 'bridge', nil, bridge = true}
      end
    end
    spend(8)
  end
  -- bounded walk over the cut group: the first closer next to it that touches a group with the class
  if cut_pos then
    local seen, q, head = {}, {key3(cut_pos[1], cut_pos[2], cut_pos[3])}, 1
    seen[q[1]] = true
    local nb, checked = {}, {}
    while head <= #q and head <= CFG.blame_max do
      local x, y, z = dec3(q[head])
      head = head + 1
      local n = steps(x, y, z, nb)
      for j = 1, n do
        local k = nb[j]
        if not seen[k] then
          seen[k] = true
          local nx, ny, nz = dec3(k)
          local g = grp(nx, ny, nz)
          if g == gc then q[#q + 1] = k
          elseif g ~= nil and not checked[k] then
            checked[k] = true
            local kind = closer_kind(nx, ny, nz)
            if kind and separates(nx, ny, nz, gc, has) then return {nx, ny, nz, kind} end
          end
        end
      end
      spend(12)
    end
  end
  for _, s in ipairs(live_stairs()) do
    if s[6] == gc then return {s[1], s[2], s[3], s[4] .. ' without counterpart'} end
  end
end

local function commit_audit(K, R, cits)
  local t = now_t(K)
  local totals, by_cls = {}, {}
  for _, cls in ipairs(VITAL) do totals[cls] = R.cls[cls].n; by_cls[cls] = R.cls[cls].by end
  local cut = cut_of(R.cit.by, by_cls, totals)
  R.cut = cut
  local dead = live_stairs()
  R.flags = reach_flags(R, dead)
  -- CUTOFF: more citizens than before lost the group of a vital class
  local inc
  for _, cls in ipairs(VITAL) do
    local d = cut[cls] - (int(st.cut[cls]) or 0)
    if d > 0 and (not inc or d > inc.d) then inc = {cls = cls, d = d} end
  end
  if inc then
    local cg, has = nil, {}
    for g, n in pairs(R.cit.by) do
      if not by_cls[inc.cls][g] and (not cg or n > R.cit.by[cg] or (n == R.cit.by[cg] and g < cg)) then cg = g end
    end
    for g in pairs(by_cls[inc.cls]) do has[g] = true end
    local cpos
    for _, c in ipairs(cits) do if c.g == cg then cpos = {c.x, c.y, c.z}; break end end
    local b = blame(K, cg, has, cpos)
    local n = cut[inc.cls]
    local what = b and string.format('%s at %d,%d,%d', b[4], b[1], b[2], b[3]) or 'cause not found'
    if b and b[5] then what = what .. ' (' .. b[5] .. ')' end
    local d = {cls = inc.cls, n = n, grp = cg or 0, main = R.main or 0, why = trunc(b and b[4] or 'unknown', 60)}
    if b then d.pos = {b[1], b[2], b[3]} end
    if b and b.bridge and GATED[K.mode()] then
      K.emit('SEAL', 'B', string.format('%d citizens shut out from %s by a raised bridge at %d,%d,%d', n, inc.cls,
             b[1], b[2], b[3]), {routes = 0, pos = d.pos, why = 'shut_out'})
    else
      K.emit('CUTOFF', 'A', string.format('%d citizens cut off from %s: %s', n, inc.cls, what), d)
    end
    R.blame = b and {b[1], b[2], b[3], b[4]} or nil
  end
  st.cut = {food = cut.food, drink = cut.drink, bed = cut.bed}
  dirty = true
  local sig = table.concat(R.flags, '|')
  if sig ~= (st.flag_sig or '') then
    st.flag_sig = sig
    if #R.flags > 0 then
      K.emit('REACH', 'B', trunc('reach: ' .. table.concat(R.flags, '; '), 200),
             {flags = (function()
               local f = {}
               for i = 1, math.min(#R.flags, 8) do f[i] = trunc(R.flags[i], 60) end
               return f
             end)(), cut = cut.food + cut.drink + cut.bed, stairs = #dead})
    end
  end
  mem.reach = R
  mem.fresh, mem.done_info = {}, {}
  mem.audit = {tick = t, burrows = R.burrows, names = R.names, cit = R.cit.n}
  -- FR-33: Kern+ fails its audit -> keep the whole-interior burrow ready
  local kb = R.burrows[R.names.kern]
  local ib = R.burrows[CFG.interior]
  if kb and not kb.ok and R.main and (not ib or not ib.exists or not ib.ok)
     and t - (int(st.painted) or -CFG.repaint) >= CFG.repaint then
    due('scan', t, 'paint', true)
  end
end

-- FR-62: what the audit reads: constructions, doors, bridges (the watcher's fingerprint), the item census, the map
-- edge, the citizens' walk groups and the burrows' blocks; equal inputs give an equal audit
local function audit_sig(K, cits)
  local cg = group_counts(cits)
  local p = {mem.fp or '-', mem.items and mem.items.tick or -1, mem.edges and mem.edges.tick or -1, K.mode()}
  for _, g in ipairs(sorted_keys(cg)) do p[#p + 1] = g .. ':' .. cg[g] end
  for _, n in ipairs((audit_names(K))) do
    local bl = block_list(n)
    p[#p + 1] = bl and #bl or -1
  end
  return table.concat(p, '|')
end

local function job_audit(K, why)
  local t = now_t(K)
  if why == 'periodic' and mem.reach and mem.audit_sig and t - mem.reach.tick < CFG.audit_max_age then
    local cits = citizens(K)
    spend(3 * #cits + 8)
    if audit_sig(K, cits) == mem.audit_sig then
      mem.last_audit = t
      mem.stats.audit_skip = (mem.stats.audit_skip or 0) + 1
      return
    end
  end
  local R, cits = audit_pass(K)
  commit_audit(K, R, cits)
  mem.audit_sig = audit_sig(K, cits)
  mem.last_audit = now_t(K)
end

-- cheap re-check after a change: the known class positions and the citizens; the full audit only when worse
local function job_quick(K)
  local R = mem.reach
  if not R then due('audit', now_t(K), 'quick'); return end
  local cits = citizens(K)
  spend(3 * #cits)
  local cg = group_counts(cits)
  local by_cls, totals = {}, {}
  for _, cls in ipairs(VITAL) do
    by_cls[cls], totals[cls] = {}, R.cls[cls].n
    for _, p in ipairs(R.reps[cls] or {}) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then by_cls[cls][g] = true end
      spend(2)
    end
  end
  local cut = cut_of(cg, by_cls, totals)
  for _, cls in ipairs(VITAL) do
    if cut[cls] > (int(st.cut[cls]) or 0) then due('audit', now_t(K), 'quick:' .. cls); return end
  end
end

---------------------------------------------------------------- map edge (FR-54 sources)
-- FR-62: dfhack.maps.isTileVisible answers "revealed?" without flag objects; it is trusted only when it agrees with
-- designation.hidden on the tiles citizens stand on, else every edge tile is read with getTileFlags
local function vis_fn(K)
  if mem.visf ~= nil then return mem.visf end
  local f = dfhack.maps.isTileVisible
  if type(f) ~= 'function' then mem.visf = false; return false end
  local n = 0
  for _, c in ipairs(citizens(K)) do
    local ok, v = pcall(f, c.x, c.y, c.z)
    if not (ok and v == true) then mem.visf = false; return false end
    n = n + 1
    if n >= 4 then break end
  end
  if n == 0 then return false end                    -- no citizen to check against: not this time
  mem.visf = f
  return f
end

-- the border as one loop per level: a run of walkable revealed tiles along it is one walk group (neighbours on the
-- border row join), so one tile per run, plus one per CFG.edge_run tiles of a long run, stands for it
local function job_edges(K)
  local X, Y, Z = map_size()
  local vf = vis_fn(K)
  local list = {}
  for z = Z - 1, 0, -1 do
    local prev, run = nil, 0
    local function try(x, y)
      local g
      if not vf or vf(x, y, z) then g = grp(x, y, z); spend(2) end
      spend(1)
      if g and g ~= 0 then
        if g ~= prev or run >= CFG.edge_run then
          if #list < CFG.edges_max then list[#list + 1] = key3(x, y, z) end
          run = 0
        end
        run = run + 1
        prev = g
      else prev = nil end
    end
    for x = 0, X - 1 do try(x, 0) end
    for y = 1, Y - 1 do try(X - 1, y) end
    for x = X - 2, 0, -1 do try(x, Y - 1) end
    for y = Y - 2, 1, -1 do try(0, y) end
  end
  local t = now_t(K)
  mem.edges = {tick = t, list = list}
  mem.due.edges = nil                                   -- a run queued meanwhile (boot) has nothing left to do
  st.edges = #list <= CFG.edges_keep and {t = t, k = list} or nil   -- known again right after a load
  dirty = true
end

---------------------------------------------------------------- perimeter manifest (FR-56)
local function perim_add(k, piece, t)
  local old = st.perim[k]
  if old then
    if piece.q and not old.q then old.q, old.fp, old.src, dirty = piece.q, piece.fp or old.fp, piece.src, true end
    return false
  end
  local n = mem.perim_n or 0
  if n >= CFG.perim_max then return false end
  piece.t = t
  st.perim[k] = piece
  mem.perim_n = n + 1
  dirty = true
  return true
end

local function perim_count()
  local n = 0
  for _ in pairs(st.perim) do n = n + 1 end
  mem.perim_n = n
  return n
end

-- one closer as a perimeter piece: a bridge by its anchor and footprint (its other tiles are the same piece)
local function record_piece(x, y, z, kind, b, src, t)
  local key, piece = kstr(x, y, z), {k = kind, src = src}
  if kind == 'bridge' then
    if not b then return false end
    key = kstr(b.x1, b.y1, b.z)
    piece.fp = {b.x1, b.y1, b.z, b.x2, b.y2, b.z}
  end
  return perim_add(key, piece, t)
end

-- manifest bridges and killbox floors (the template geometry)
local function perim_manifest(K, t)
  local man = K.manifest()
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    local fp = type(b) == 'table' and b.fp
    if type(fp) == 'table' and #fp == 6 then
      perim_add(kstr(fp[1], fp[2], fp[3]), {k = 'bridge', fp = {fp[1], fp[2], fp[3], fp[4], fp[5], fp[6]},
                                           name = name, src = 'manifest'}, t)
    end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    local bb = type(kb) == 'table' and kb.bbox
    if type(bb) == 'table' and #bb == 6 then
      for z = bb[3], bb[6] do
        for y = bb[2], bb[5] do
          for x = bb[1], bb[4] do
            local g = grp(x, y, z)
            if g and g ~= 0 then perim_add(kstr(x, y, z), {k = 'killbox', id = kb.id, src = 'manifest'}, t) end
            spend(2)
          end
        end
      end
    end
  end
end

local function piece_state(k, p)
  local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
  x, y, z = int(tonumber(x)), int(tonumber(y)), int(tonumber(z))
  if not (x and y and z) then return 'unknown' end
  local des = rev(x, y, z)
  if not des then return 'unknown' end
  if p.k == 'wall' or p.k == 'fort' then
    local s = shape(x, y, z)
    return (s and (s.shape == 'WALL' or s.shape == 'FORTIFICATION')) and 'ok' or 'gone'
  elseif p.k == 'bridge' then
    return bridge_at(p.fp or {x, y, z, x, y, z}) and 'ok' or 'gone'
  elseif p.k == 'killbox' then
    local g = grp(x, y, z)
    return (g and g ~= 0) and 'ok' or 'gone'
  end
  local b = bld_at(x, y, z)
  return (b and BKIND[btype(b) or ''] == p.k) and 'ok' or 'gone'
end

-- pre: a siege begins: pieces already gone are retired (a wall the player removed is never rebuilt);
-- retire: the same in PEACE; post: after the siege, lost pieces are re-queued and reported
local function job_perim(K, why)
  local t = now_t(K)
  perim_manifest(K, t)
  local gone = {}
  for _, k in ipairs(sorted_keys(st.perim)) do
    local p = st.perim[k]
    if p and piece_state(k, p) == 'gone' then gone[#gone + 1] = k end
    spend(4)
  end
  mem.perim_diff = {tick = t, why = why, gone = gone}
  if why ~= 'post' then
    for _, k in ipairs(gone) do st.perim[k] = nil end
    if #gone > 0 then
      dirty = true
      K.log('info', 'seal: %d perimeter pieces retired (%s)', #gone, why)
    end
    perim_count()
    return
  end
  local fresh = {}
  for _, k in ipairs(gone) do
    local last = int(st.req[k])
    if not (last and t - last < CFG.requeue_cool) then fresh[#fresh + 1] = k end
  end
  if #fresh == 0 then return end
  local cells, kinds, kseen = {}, {}, {}
  for _, k in ipairs(fresh) do
    local p = st.perim[k]
    if not kseen[p.k] then kseen[p.k] = true; kinds[#kinds + 1] = p.k end
    local q = p.q or QF_OF[p.k]
    if q then
      local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
      cells[#cells + 1] = {int(tonumber(x)), int(tonumber(y)), int(tonumber(z)), q}
    end
    st.req[k] = t
  end
  local queued, proj = 0, nil
  if #cells > 0 then
    local ok, r1, r2 = K.call('runner', 'repair', cells, 'perimeter after the siege')
    if ok and r1 then queued, proj = #cells, r2
    else K.log('warn', 'seal: repair not queued: %s', tostring(r2 or r1)) end
  end
  dirty = true
  local x, y, z = fresh[1]:match('^(-?%d+),(-?%d+),(-?%d+)$')
  local p0 = st.perim[fresh[1]]
  K.emit('PERIMETER_BROKEN', 'A', string.format('%d perimeter pieces lost (%s %s): %d re-queued%s', #fresh, p0.k,
         fresh[1], queued, proj and (' as ' .. proj) or ''),
         {n = #fresh, pos = {int(tonumber(x)), int(tonumber(y)), int(tonumber(z))}, kinds = kinds, requeued = queued,
          why = why})
end

---------------------------------------------------------------- entrances (FR-54)
local function bridges_expect_sealed(K)
  local man = K.manifest()
  local n = 0
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and (b.role == 'outer' or b.role == 'inner') then
      n = n + 1
      local ok, s = K.call('gate', 'state', name)
      if not (ok and s == 'up') then return false end
    end
  end
  return n > 0
end

-- building and its state on a tile (Door locked, Bridge down, ...), else the tile shape ('floor', 'ramp', ...)
local function describe_tile(x, y, z)
  local des, occ = rev(x, y, z)
  if not des then return 'hidden', '-' end
  local b = bld_on(x, y, z, occ)
  if b then return bstate(b) end
  local s = shape(x, y, z)
  return s and s.shape and s.shape:lower() or '?', 'no door'
end

-- union of entries whose inside tiles touch (Chebyshev <= 1): the independent openings of the interior
local function routes_of(entries)
  local parent = {}
  local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end; return i end
  for i = 1, #entries do parent[i] = i end
  for i = 1, #entries do
    local a = entries[i]
    for j = i + 1, #entries do
      local b = entries[j]
      if math.abs(a.x - b.x) <= 1 and math.abs(a.y - b.y) <= 1 and math.abs(a.z - b.z) <= 1 then
        local ri, rj = find(i), find(j)
        if ri ~= rj then parent[rj] = ri end
      end
    end
    spend(1)
  end
  local reps, at = {}, {}
  for i = 1, #entries do
    local r = find(i)
    local e = entries[i]
    if not at[r] then
      reps[#reps + 1] = {x = e.x, y = e.y, z = e.z, ox = e.ox, oy = e.oy, oz = e.oz, d = e.d, n = 1}
      at[r] = #reps
    else
      local c = reps[at[r]]
      c.n = c.n + 1
      if e.d < c.d then c.x, c.y, c.z, c.ox, c.oy, c.oz, c.d = e.x, e.y, e.z, e.ox, e.oy, e.oz, e.d end
    end
  end
  table.sort(reps, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return key3(a.x, a.y, a.z) < key3(b.x, b.y, b.z)
  end)
  return reps
end

-- the entrance search from `sources` ({x,y,z}) over revealed tiles of walk group G, in two phases.
-- 1. A BFS over the inside tiles (all of them): entries = inside tiles next to outside tiles of G (the openings);
--    the outside tiles next to them (and outside sources) form the frontier. `learned` = blocked tiles next to the
--    visited ones (perimeter candidates).
-- 2. `trace`: an A* from the frontier over the tiles of G to the nearest map-edge tile (heuristic: the distance to
--    the nearest map edge, never more than the steps left), so the route outside is walked, not the whole surface
--    (FR-62: the old BFS flooded the outside until it met the edge)
local function heap_push(h, f, k)
  local n = #h.k + 1
  h.k[n], h.f[n] = k, f
  while n > 1 do
    local p = n // 2
    if h.f[p] <= h.f[n] then break end
    h.k[p], h.k[n], h.f[p], h.f[n] = h.k[n], h.k[p], h.f[n], h.f[p]
    n = p
  end
end
local function heap_pop(h)
  local n = #h.k
  if n == 0 then return nil end
  local k = h.k[1]
  h.k[1], h.f[1] = h.k[n], h.f[n]
  h.k[n], h.f[n] = nil, nil
  n = n - 1
  local i = 1
  while true do
    local l, r, m = 2 * i, 2 * i + 1, i
    if l <= n and h.f[l] < h.f[m] then m = l end
    if r <= n and h.f[r] < h.f[m] then m = r end
    if m == i then break end
    h.k[m], h.k[i], h.f[m], h.f[i] = h.k[i], h.k[m], h.f[i], h.f[m]
    i = m
  end
  return k
end

local function bfs(K, G, sources, X, Y, trace)
  local par, outs, depth, rtop = {}, {}, {}, {}
  local q, head, visited = {}, 1, 0
  local edge_k, partial = nil, false
  local entries, ent_seen, learned, front = {}, {}, {}, {}
  local function eval(k)                     -- 1 outside, 0 inside, false = hidden or another walk group
    local o = outs[k]
    if o ~= nil then return o end
    local x, y, z = dec3(k)
    local des = rev(x, y, z)
    if not des then outs[k] = false; spend(1); return false end
    P.x, P.y, P.z = x, y, z
    spend(2)
    if (dfhack.maps.getWalkableGroup(P) or 0) ~= G then
      outs[k] = false
      learned[#learned + 1] = k
      return false
    end
    o = des.outside and 1 or 0
    outs[k] = o
    return o
  end
  local function entry(ik, ok_, d)
    if ent_seen[ik] or #entries >= CFG.entries_max then return end
    ent_seen[ik] = true
    local x, y, z = dec3(ik)
    local ox, oy, oz = dec3(ok_)
    entries[#entries + 1] = {x = x, y = y, z = z, ox = ox, oy = oy, oz = oz, d = d}
  end
  local function on_edge(k)
    local x, y = dec3(k)
    return x == 0 or y == 0 or x == X - 1 or y == Y - 1
  end
  -- the walkable neighbours of k (DF moves, down a ramp included): calls f(nk, o) for each
  local nb = {}
  local function each(k, sh, f)
    local x, y, z = dec3(k)
    local n = steps(x, y, z, nb, sh)
    for i = 1, n do
      local nk = nb[i]
      local o = eval(nk)
      if o ~= false then f(nk, o)
      elseif i <= 8 then
        -- down a ramp: a blocked neighbour that is the open top of a ramp one level down
        if rtop[nk] == nil then rtop[nk] = ramp_top(nk); spend(2) end
        if rtop[nk] then
          local dk = nk - 16777216
          local od = eval(dk)
          if od ~= false then f(dk, od) end
        end
      end
    end
    spend(2)
  end
  for _, c in ipairs(sources) do
    local k = key3(c[1], c[2], c[3])
    local o = par[k] == nil and eval(k)
    if o == 0 then par[k], depth[k] = -1, 0; q[#q + 1] = k
    elseif o == 1 then par[k], depth[k] = -1, 0; front[#front + 1] = k end
  end
  -- phase 1: the interior; an outside source looks at its neighbours too (the inside behind an opening)
  for _, k in ipairs(front) do
    each(k, nil, function(nk, o)
      if o == 0 then
        entry(nk, k, 1)
        if par[nk] == nil then par[nk], depth[nk] = k, 1; q[#q + 1] = nk end
      end
    end)
  end
  local cur
  local function inside_step(nk, o)
    if o == 1 then
      entry(cur, nk, depth[cur])
      if par[nk] == nil then par[nk], depth[nk] = cur, depth[cur] + 1; front[#front + 1] = nk end
    elseif par[nk] == nil then
      par[nk], depth[nk] = cur, depth[cur] + 1
      q[#q + 1] = nk
    end
  end
  while head <= #q do
    if visited >= CFG.bfs_max then partial = true; break end
    cur = q[head]
    head, visited = head + 1, visited + 1
    if not edge_k and on_edge(cur) then edge_k = cur end
    each(cur, nil, inside_step)
  end
  -- phase 2: the route to the map edge
  if trace and not edge_k and not partial then
    local h, g, done, fixed = {k = {}, f = {}}, {}, {}, {}
    local function hcost(k)
      local x, y = dec3(k)
      return math.min(x, y, X - 1 - x, Y - 1 - y)
    end
    for k in pairs(par) do fixed[k] = true end         -- phase 1 tiles keep their parents (no cycles)
    for _, k in ipairs(front) do
      g[k] = depth[k]
      heap_push(h, depth[k] + hcost(k), k)
    end
    while true do
      local k = heap_pop(h)
      if not k then break end
      if not done[k] then
        done[k] = true
        if on_edge(k) then edge_k = k; break end
        if visited >= CFG.bfs_max then partial = true; break end
        visited = visited + 1
        each(k, nil, function(nk)
          local gn = g[k] + 1
          if not done[nk] and not fixed[nk] and (g[nk] == nil or gn < g[nk]) then
            g[nk], par[nk] = gn, k
            heap_push(h, gn + hcost(nk), nk)
          end
        end)
      end
    end
  end
  return {par = par, outs = outs, edge = edge_k, entries = entries, partial = partial, visited = visited,
          learned = learned}
end

-- BFS and scan sources on the groups `on` (nil = any): the citizens, plus (`inner`) beds and stock tiles of the last
-- audit, so an untraced BFS or the scan finds the interior while every citizen works outside
local function sources_on(cits, on, inner)
  local src, seen = {}, {}
  local function push(x, y, z)
    local k = key3(x, y, z)
    if not seen[k] then seen[k] = true; src[#src + 1] = {x, y, z} end
  end
  for _, c in ipairs(cits) do if not on or on[c.g] then push(c.x, c.y, c.z) end end
  if inner then
    for _, cls in ipairs({'bed', 'drink', 'food'}) do
      for _, p in ipairs(mem.reach and mem.reach.reps[cls] or {}) do push(p[1], p[2], p[3]) end
    end
  end
  return src
end

-- a closer tile next to a tile of the citizens' groups `cg` (8 on the level, above, below)
local function borders(x, y, z, cg)
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local g = grp(x + dx, y + dy, z)
        if g and cg[g] then return true end
      end
    end
  end
  for _, dz in ipairs({-1, 1}) do
    local g = grp(x, y, z + dz)
    if g and cg[g] then return true end
  end
  return false
end

-- learn the perimeter from a BFS: closers next to an inside tile that border an outside tile or a walk group that
-- reaches the map edge (E), and the doors, hatches and bridges on the openings
local function learn_perimeter(K, B, reps, E, G)
  local t = now_t(K)
  local added = 0
  for _, k in ipairs(B.learned) do
    local x, y, z = dec3(k)
    local kind, b = closer_at(x, y, z)
    spend(2)
    if kind and REC[kind] then
      local inner, outer = false, false
      for dy = -1, 1 do
        for dx = -1, 1 do
          if dx ~= 0 or dy ~= 0 then
            local o = B.outs[key3(x + dx, y + dy, z)]
            if o == 0 then inner = true
            elseif o == 1 then outer = true
            else
              local des = rev(x + dx, y + dy, z)
              if des and des.outside then outer = true
              elseif des then
                local g = grp(x + dx, y + dy, z)
                if g and g ~= 0 and g ~= G and E[g] then outer = true end
              end
              spend(2)
            end
          end
        end
      end
      if inner and outer and record_piece(x, y, z, kind, b, 'seal', t) then added = added + 1 end
    end
  end
  for _, r in ipairs(reps) do
    local des, occ = rev(r.x, r.y, r.z)
    local b = des and bld_on(r.x, r.y, r.z, occ)
    local kind = b and BKIND[btype(b) or '']
    if kind and REC[kind] and record_piece(r.x, r.y, r.z, kind, b, 'seal', t) then added = added + 1 end
    spend(2)
  end
  if added > 0 then K.log('info', 'seal: %d perimeter pieces learned', added) end
  return added
end

---------------------------------------------------------------- openings (FR-60)
-- a known opening {x,y,z, ox,oy,oz} (inside tile, outside tile) still joins the inside to the outside of group G
local function opening_open(o, G)
  local gi = grp(o[1], o[2], o[3])
  return gi ~= nil and gi ~= 0 and gi == G and grp(o[4], o[5], o[6]) == G
end

-- every wall, door, gate or bridge around a sealed opening's inside and outside tile (one level up and down for
-- stairs and ramps) that borders the citizens' groups
local function record_opening(o, cg, t)
  local r, n, seen = CFG.rec_r, 0, {}
  for _, c in ipairs({{o[1], o[2], o[3]}, {o[4], o[5], o[6]}}) do
    for z = c[3] - 1, c[3] + 1 do
      for y = c[2] - r, c[2] + r do
        for x = c[1] - r, c[1] + r do
          local k = kstr(x, y, z)
          if not seen[k] then
            seen[k] = true
            local kind, b = closer_at(x, y, z)
            spend(2)
            if kind and REC[kind] then
              spend(20)
              if borders(x, y, z, cg) and record_piece(x, y, z, kind, b, 'entrance', t) then n = n + 1 end
            end
          end
        end
      end
    end
  end
  return n
end

-- the openings the last complete BFS found are persisted; one gone from a later complete BFS (or every one, once the
-- fort is sealed) was sealed: its walls, doors, gates and bridges become perimeter pieces (FR-60, no manifest needed)
local function track_openings(K, res, B, cg)
  local t = now_t(K)
  local prev = st.open or {}
  local closed = {}
  if res.sealed then
    closed = prev
    if #prev > 0 then st.open, dirty = {}, true end
  elseif B and not B.partial and #B.entries < CFG.entries_max then
    for _, o in ipairs(prev) do
      local still = false
      for _, e in ipairs(B.entries) do
        if math.abs(e.x - o[1]) <= 1 and math.abs(e.y - o[2]) <= 1 and math.abs(e.z - o[3]) <= 1 then
          still = true
          break
        end
      end
      if not still then closed[#closed + 1] = o end
    end
    local cur = {}
    for i, r in ipairs(res.openings) do
      if i > CFG.routes_max then break end
      cur[i] = {r.pos[1], r.pos[2], r.pos[3], r.out[1], r.out[2], r.out[3]}
    end
    st.open, dirty = cur, true
  end
  local added = 0
  for _, o in ipairs(closed) do added = added + record_opening(o, cg, t) end
  if #closed > 0 then
    res.closed = #closed
    K.log('info', 'seal: %d opening%s sealed, %d perimeter pieces recorded', #closed, #closed == 1 and '' or 's', added)
  end
  return added
end

-- the BFS runs when its answer can change; in PEACE the open gates (D-14) leak by design, so a periodic or a
-- construction check there re-uses the last answer unless a known opening closed or CFG.bfs_every passed
local BFS_WHY = {inspect = true, record = true, lever = true, siege = true}

local function job_seal(K, why)
  why = why or ''
  local t0 = now_t(K)
  local rec = mem.rec_req                        -- cleared at the end (a dropped run keeps the request)
  if not mem.edges then job_edges(K) end
  local X, Y = map_size()
  local cits = citizens(K)
  spend(3 * #cits)
  local res = {tick = t0, why = why, sealed = false, routes = 0, openings = {}}
  if #cits == 0 then
    res.msg = 'no citizen on a revealed walkable tile'
    mem.seal = res
    if rec then
      mem.rec = {tick = t0, added = 0, n = mem.perim_n or 0, msg = res.msg}
      if mem.rec_req == rec then mem.rec_req = nil end
    end
    return
  end
  local cg, main = group_counts(cits)
  local E = {}
  for _, k in ipairs(mem.edges.list) do
    local x, y, z = dec3(k)
    local g = grp(x, y, z)
    if g and g ~= 0 and not E[g] then E[g] = k end
    spend(2)
  end
  local leak = {}
  for _, g in ipairs(sorted_keys(cg)) do if E[g] then leak[#leak + 1] = g end end
  local mode = K.mode()
  local expect = bridges_expect_sealed(K)
  local prev = mem.seal
  local B, added = nil, 0
  if #leak == 0 then
    res.sealed, res.msg = true, 'seal verified: no route'
  else
    local G = leak[1]
    for _, g in ipairs(leak) do if cg[g] > cg[G] then G = g end end
    local need = expect or mode ~= 'PEACE' or rec or BFS_WHY[why] or not (prev and prev.bfs) or prev.sealed
                 or t0 - prev.bfs >= CFG.bfs_every
    if not need then
      for _, o in ipairs(st.open or {}) do         -- a known opening closed (walled up, a bridge raised)
        spend(4)
        if not opening_open(o, G) then need = true; break end
      end
    end
    if not need then
      -- FR-62: the gates stand open in PEACE, the fort leaks by design and no known opening changed: the last BFS
      -- answer stands
      for k, v in pairs(prev) do res[k] = v end
      res.tick, res.why, res.reused, res.closed = t0, why, true, nil
      mem.stats.bfs_skip = (mem.stats.bfs_skip or 0) + 1
    else
      local src = sources_on(cits, {[G] = true}, true)
      B = bfs(K, G, src, X, Y, true)
      mem.stats.bfs = (mem.stats.bfs or 0) + 1
      res.bfs = t0
      local reps = routes_of(B.entries)
      res.routes, res.partial, res.visited = #reps, B.partial, B.visited
      for i = 1, math.min(#reps, CFG.routes_max) do
        local r = reps[i]
        local bt, bs = describe_tile(r.x, r.y, r.z)
        local ot, os_ = describe_tile(r.ox, r.oy, r.oz)
        res.openings[i] = {pos = {r.x, r.y, r.z}, out = {r.ox, r.oy, r.oz}, n = r.n, d = r.d,
                           bld = bt, state = bs, out_bld = ot, out_state = os_}
      end
      -- the first leak: walking back from the first map-edge tile, the first inside tile is where the route
      -- enters the fort; buildings on the route are listed with their state
      if B.edge then
        local path, k = {}, B.edge
        while k and k ~= -1 and #path < 5000 do path[#path + 1] = k; k = B.par[k] end
        local first, via = nil, {}
        for _, pk in ipairs(path) do
          local x, y, z = dec3(pk)
          if not first and B.outs[pk] == 0 then first = {x, y, z} end
          local des, occ = rev(x, y, z)
          local b = des and bld_on(x, y, z, occ)
          if b and #via < 4 then
            local bt, bs = bstate(b)
            via[#via + 1] = string.format('%s %s at %d,%d,%d', bt, bs, x, y, z)
          end
        end
        local ex, ey, ez = dec3(B.edge)
        res.edge = {ex, ey, ez}
        res.len = #path - 1
        res.via = via
        if first then
          local bt, bs = describe_tile(first[1], first[2], first[3])
          res.first = {pos = first, bld = bt, state = bs}
          -- a perimeter piece that should stand next to the leak
          for dy = -1, 1 do
            for dx = -1, 1 do
              local pk = kstr(first[1] + dx, first[2] + dy, first[3])
              local p = st.perim[pk]
              if p and piece_state(pk, p) == 'gone' then res.first.missing = p.k .. ' ' .. pk end
            end
          end
          res.msg = string.format('LEAK at %d,%d,%d (%s %s)%s', first[1], first[2], first[3], tostring(bt),
                                  tostring(bs), res.first.missing and (', ' .. res.first.missing .. ' missing') or '')
        else
          res.first = {pos = {src[1][1], src[1][2], src[1][3]}, open = true}
          res.msg = string.format('LEAK: open route from %d,%d,%d to the map edge without a roofed tile',
                                  src[1][1], src[1][2], src[1][3])
        end
      else
        res.msg = string.format('LEAK: group %d reaches the map edge, route not traced (%s)', G,
                                B.partial and 'search limit' or 'unrevealed or climbing')
      end
      res.msg = res.msg .. string.format('; %d independent route%s', res.routes, res.routes == 1 and '' or 's')
      if mode == 'PEACE' or rec then added = added + learn_perimeter(K, B, reps, E, G) end
    end
  end
  added = added + track_openings(K, res, B, cg)
  if rec then
    -- perimeter.record on a sealed fort: the boundary of the citizens' main group (closers between it and the
    -- outside or a walk group that reaches the map edge)
    if res.sealed and main then
      local Bm = bfs(K, main, sources_on(cits, {[main] = true}, true), X, Y, false)
      added = added + learn_perimeter(K, Bm, {}, E, main)
    end
    mem.rec = {tick = t0, added = added, n = mem.perim_n or 0, sealed = res.sealed and 1 or 0}
    K.log('info', 'seal: perimeter.record: %d pieces added, %d in all', added, mem.perim_n or 0)
    if mem.rec_req == rec then mem.rec_req = nil end
  end
  res.expect = expect
  mem.seal = res
  local pos = res.first and res.first.pos or nil
  if not res.sealed and expect then
    -- BUG-008: the same leak is announced once per episode; a new leak tile or state is news and goes out at once
    -- (a new way in during a siege must not wait for the cadence). A sealed check ends the episode.
    local ids = {pos and table.concat(pos, ',') or '?'}
    local toks = {tostring(res.first and res.first.state or ''), tostring(res.first and res.first.bld or '')}
    local now = K.now()
    if CAD.due(st.leak_rec, now, ids, toks, {ticks = 0, wall_s = 0}) then
      st.leak_rec, dirty = CAD.mark(now, ids, toks), true
      K.emit('SEAL_LEAK', 'A', trunc(res.msg, 200), {routes = res.routes, pos = pos, bld = res.first and res.first.bld,
             state = res.first and res.first.state, why = trunc(why, 40)})
    end
  elseif why ~= 'inspect' and (not (why == 'periodic' or res.reused) or not prev or prev.sealed ~= res.sealed
                               or prev.routes ~= res.routes) then
    K.emit('SEAL', 'B', trunc(res.msg, 200), {routes = res.routes, pos = pos, why = trunc(why, 40),
           sealed = res.sealed and 1 or 0})
  end
  st.seal = {t = t0, sealed = res.sealed and 1 or 0, routes = res.routes}
  if res.sealed then st.leak_rec = nil end
  dirty = true
end

---------------------------------------------------------------- scan: stairs without counterpart, interior tiles
-- tiles the interior burrow must not hold: the attack path (manifest Z1/Z2) and the kill boxes
local function excluded(K)
  local man, ex = K.manifest(), {}
  for _, key in ipairs({'Z1', 'Z2'}) do
    for _, b in ipairs(type(man.zones) == 'table' and type(man.zones[key]) == 'table' and man.zones[key] or {}) do
      ex[#ex + 1] = b
    end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if type(kb) == 'table' and type(kb.bbox) == 'table' then ex[#ex + 1] = kb.bbox end
  end
  return ex
end

local function in_any(ex, x, y, z)
  for _, e in ipairs(ex) do
    if x >= e[1] and x <= e[4] and y >= e[2] and y <= e[5] and z >= e[3] and z <= e[6] then return true end
  end
  return false
end

-- FR-62/63: a flood over the citizens' walk groups (their inside tiles and the outside tiles next to them) finds the
-- stairs without counterpart and the interior tiles, instead of a box scan that read mostly hidden rock
local function job_scan(K, paint)
  local cits = citizens(K)
  spend(3 * #cits)
  local cg, main = group_counts(cits)
  local res = {tick = now_t(K), stairs = {}, n = 0}
  local ex = paint and excluded(K) or {}
  local inner = paint and main and {} or nil
  local gk, out = {}, {}              -- key -> walk group (false: hidden, unwalkable or no citizens' group), outside
  local q, head = {}, 1
  local function eval(k)
    local g = gk[k]
    if g ~= nil then return g end
    local x, y, z = dec3(k)
    local des = rev(x, y, z)
    if not des then gk[k] = false; spend(1); return false end
    P.x, P.y, P.z = x, y, z
    g = dfhack.maps.getWalkableGroup(P) or 0
    spend(2)
    if not cg[g] then gk[k] = false; return false end
    gk[k], out[k] = g, des.outside == true
    return g
  end
  for _, p in ipairs(sources_on(cits, nil, true)) do
    local k = key3(p[1], p[2], p[3])
    if gk[k] == nil and eval(k) then q[#q + 1] = k end
  end
  local nb, rtop = {}, {}
  while head <= #q do
    if head > CFG.scan_max then res.partial = true; break end
    local k = q[head]
    head = head + 1
    local x, y, z = dec3(k)
    local s = shape(x, y, z)
    local sh = s and s.shape
    spend(1)
    if sh and STAIR_KIND[sh] and #res.stairs < CFG.stairs_max then
      local kind, why = stair_dead(x, y, z, sh)
      spend(4)
      if kind then res.stairs[#res.stairs + 1] = {x, y, z, kind, why, gk[k]} end
    end
    if not out[k] then                -- inside tiles expand; the outside ones next to them are only looked at
      if inner and gk[k] == main and #inner < CFG.interior_max and not in_any(ex, x, y, z) then
        inner[#inner + 1] = {x, y, z}
      end
      local n = steps(x, y, z, nb, sh or false)
      for i = 1, n do
        local nk = nb[i]
        if gk[nk] == nil then
          if eval(nk) then q[#q + 1] = nk
          elseif i <= 8 then
            if rtop[nk] == nil then rtop[nk] = ramp_top(nk); spend(2) end
            local dk = nk - 16777216
            if rtop[nk] and gk[dk] == nil and eval(dk) then q[#q + 1] = dk end
          end
        end
      end
    end
  end
  res.n = head - 1
  mem.scan = res
  if inner and #inner > 0 then mem.paint_list = inner; due('paint', now_t(K), 'interior') end
end

-- FR-33: the whole-interior burrow (burrows screen: add burrow, paint tiles), in chunks
local function job_paint(K)
  local list = mem.paint_list
  mem.paint_list = nil
  if not list or #list == 0 then return end
  local n, i = 0, 1
  while i <= #list do
    local chunk = {}
    for j = i, math.min(#list, i + CFG.paint_chunk - 1) do chunk[#chunk + 1] = list[j] end
    i = i + #chunk
    local ok, r = K.act.burrow_tiles(CFG.interior, chunk, true)
    if not ok then K.log('warn', 'seal: painting %s failed: %s', CFG.interior, tostring(r)); break end
    n = n + (int(r) or 0)
    spend(CFG.work)                                          -- one chunk per frame
  end
  st.painted, dirty = now_t(K), true
  mem.bsize[CFG.interior] = nil
  K.log('info', 'seal: %s painted with %d of %d interior tiles', CFG.interior, n, #list)
  due('audit', now_t(K), 'painted')
end

---------------------------------------------------------------- the alert burrow (FR-33/37/57)
-- the civ-alert burrow for `mode`: want = default (siege: Kern+, or the refuge in BREACH); after a BREACH the
-- refuge is held until CFG.back_days without a visible hostile; a burrow that fails its audit is refused for Kern+,
-- then the interior burrow; nil = no confinement. Returns choice, want, why (the refusal) without side effects.
local function choose(K, mode, want)
  local kern, refuge = burrow_names(K)
  want = want or (mode == 'BREACH' and refuge or kern)
  if st.swap and want == kern and mode ~= 'PEACE' and quiet(K) < CFG.back_days * DAY then want = refuge end
  local chain = {want}
  if want ~= kern then chain[#chain + 1] = kern end
  if CFG.interior ~= want and CFG.interior ~= kern then chain[#chain + 1] = CFG.interior end
  local au = mem.audit and mem.audit.burrows
  if not au then return want, want, nil end                -- no audit yet (it runs at boot): as before
  local why
  for _, name in ipairs(chain) do
    local a = au[name]
    if a and a.exists and a.ok then return name, want, why end
    if a and a.exists and not why then why = name .. ': ' .. a.why end
  end
  return nil, want, why
end

local function publish(K)
  local mode = K.mode()
  local pick, want, why = choose(K, mode == 'PEACE' and 'ALERT' or mode, nil)
  local au = mem.audit and mem.audit.burrows or {}
  local a = pick and au[pick]
  mem.pub = {want = trunc(want, 24), burrow = trunc(pick or '', 24), tiles = a and a.tiles or 0,
             inside = a and a.inside or 0, ok = (pick == want and (au[want] == nil or au[want].ok)) and 1 or 0,
             why = trunc(why or '', 40)}
end

-- public (CONTRACTS §7, siege): the burrow the civ alert confines to in `mode`; nil = no confinement
function M.alert_burrow(K, mode, default)
  mode = mode or K.mode()
  local kern, refuge = burrow_names(K)
  if default ~= kern then default = (mode == 'BREACH' or default ~= nil) and refuge or kern end
  local t = now_t(K)
  if mode == 'BREACH' then
    local au = mem.audit and mem.audit.burrows
    local r = au and au[refuge]
    if (default or refuge) == refuge and (not au or (r and r.ok)) then
      if not st.swap then st.swap, dirty = {since = t}, true end
    end
  elseif st.swap and (mode == 'PEACE' or quiet(K) >= CFG.back_days * DAY) then
    st.swap, dirty = nil, true
    K.log('info', 'seal: refuge released, confinement back to %s', kern)
  end
  local pick, want, why = choose(K, mode, default)
  if pick ~= want and why then
    -- BUG-008: once per episode, again only when the refused burrow, the fallback or the reason changed, and then
    -- not before max(1 game day, 60 s wall clock) (util/cadence; the unconditional daily repeat was 3 s at timestream)
    local ids, toks, now = {want .. '>' .. tostring(pick)}, {trunc(why, 60)}, K.now()
    if CAD.due(st.refuge_rec, now, ids, toks, {ticks = DAY, wall_s = 60}) then
      st.refuge_rec, dirty = CAD.mark(now, ids, toks), true
      local au = mem.audit and mem.audit.burrows or {}
      local a = pick and au[pick]
      K.emit('REFUGE_FAIL', 'A', trunc(string.format('alert burrow %s refused (%s): %s', want, why,
             pick and ('confining to ' .. pick) or 'no confinement, the whole fort'), 200),
             {burrow = want, fallback = pick or '', why = trunc(why, 120), tiles = a and a.tiles or 0,
              inside = a and a.inside or 0, mode = mode})
    end
  end
  if pick == want and st.refuge_rec then st.refuge_rec, dirty = nil, true end   -- the episode ended
  publish(K)
  save(K)
  return pick
end

-- public (FR-33, sense): entrances a wild large predator must be near to count; nil when none is known
function M.entrances(K)
  local list = {}
  for _, r in ipairs(mem.seal and mem.seal.openings or {}) do
    if #list < 24 then list[#list + 1] = {r.pos[1], r.pos[2], r.pos[3]} end
  end
  local man = K.manifest()
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and b.role == 'outer' and type(b.fp) == 'table' and #b.fp == 6 then
      list[#list + 1] = {(b.fp[1] + b.fp[4]) // 2, (b.fp[2] + b.fp[5]) // 2, b.fp[3]}
    end
  end
  for _, p in ipairs(type(man.edge) == 'table' and man.edge or {}) do
    if #list < 40 and type(p) == 'table' and int(p[1]) then list[#list + 1] = {p[1], p[2], p[3]} end
  end
  if #list == 0 then return nil end
  return list, CFG.pred_near
end

---------------------------------------------------------------- runner hook (FR-22 "before", FR-56 record)
-- public (runner.apply, before a build chunk goes to quickfort): remember its closing cells (walls, doors, bridges,
-- ...) and take a fresh reach baseline; the watcher finds them built later
local function extents(text)
  local w, h = text:match('%((%-?[0-9]+)x(%-?[0-9]+)%)')
  return math.max(-100, math.min(100, int(tonumber(w)) or 1)), math.max(-100, math.min(100, int(tonumber(h)) or 1))
end

function M.closing(K, proj, tpl, class, ch)
  if type(ch) ~= 'table' or type(ch.pos) ~= 'table' or type(ch.cells) ~= 'table' then return 0 end
  local t, n = now_t(K), 0
  for _, c in ipairs(ch.cells) do
    local text = type(c) == 'table' and type(c[4]) == 'string' and c[4] or ''
    local kind = CLOSERS[text:match('^[^{(:/]*')]
    local x0, y0, z0 = int(ch.pos[1]), int(ch.pos[2]), int(ch.pos[3])
    if kind and x0 and int(c[1]) then
      x0, y0, z0 = x0 + c[1], y0 + c[2], z0 + c[3]
      local w, h = extents(text)
      if w < 0 then x0, w = x0 + w + 1, -w end
      if h < 0 then y0, h = y0 + h + 1, -h end
      local anchor = kstr(x0, y0, z0)
      for dy = 0, h - 1 do
        for dx = 0, w - 1 do
          if mem.npend < CFG.pend_max then
            local k = key3(x0 + dx, y0 + dy, z0)
            if not mem.pend[k] then mem.npend = mem.npend + 1 end
            mem.pend[k] = {kind = kind, q = kind == 'bridge' and text or text:match('^[^{(:/]*'), proj = proj,
                           tpl = tpl, class = class, a = anchor, fp = kind == 'bridge' and
                           {x0, y0, z0, x0 + w - 1, y0 + h - 1, z0} or nil, t = t}
            n = n + 1
          end
        end
      end
    end
  end
  if n > 0 and (not mem.reach or t - mem.reach.tick > CFG.quick_min) then
    due('audit', t, 'before ' .. tostring(proj))
  end
  return n
end

-- pending closers that are built now: candidates for blame; defense projects add them to the perimeter
local function check_pending(K)
  local t, done = now_t(K), 0
  for k, p in pairs(mem.pend) do
    local x, y, z = dec3(k)
    local ok = false
    if rev(x, y, z) then
      if p.kind == 'wall' or p.kind == 'fort' then
        local s = shape(x, y, z)
        ok = s ~= nil and (s.shape == 'WALL' or s.shape == 'FORTIFICATION') and s.mat == 'CONSTRUCTION'
      else
        local b = p.kind == 'bridge' and bridge_at(p.fp) or bld_at(x, y, z)
        ok = b ~= nil and built(b) and BKIND[btype(b) or ''] == p.kind
      end
    end
    if ok then
      done = done + 1
      mem.pend[k], mem.npend = nil, mem.npend - 1
      table.insert(mem.fresh, 1, k)
      while #mem.fresh > 64 do mem.done_info[table.remove(mem.fresh)] = nil end
      mem.done_info[k] = {kind = p.kind, proj = p.proj}
      if p.class == 'defense' then
        local pk = p.kind == 'bridge' and p.a or kstr(x, y, z)
        perim_add(pk, {k = p.kind, q = p.q, fp = p.fp, src = p.proj}, t)
      end
    elseif t - p.t > 60 * DAY then
      mem.pend[k], mem.npend = nil, mem.npend - 1        -- never built (cancelled): forget
    end
  end
  return done
end

---------------------------------------------------------------- watcher
local function fingerprint()
  local parts = {}
  local ok, n = pcall(function() return #df.global.world.constructions end)
  parts[1] = ok and n or -1
  for _, cat in ipairs({'DOOR', 'HATCH', 'BRIDGE', 'FLOODGATE', 'GRATE_WALL', 'BARS_VERTICAL'}) do
    parts[#parts + 1] = vlen(vec('buildings', cat))
  end
  local bv = vec('buildings', 'BRIDGE')
  for i = 0, math.min(vlen(bv), 32) - 1 do
    local b = bv[i]
    if b then
      local _, s = bstate(b)
      parts[#parts + 1] = s
    end
  end
  return table.concat(parts, ',')
end

local function watch(K, t)
  local h = K.census.h
  if type(h) == 'table' and (h.vis or 0) > 0 and int(h.tick) and st.hostile ~= h.tick then
    if not st.hostile or h.tick - st.hostile >= DAY then dirty = true end   -- persisted about once a day
    st.hostile = h.tick
  end
  if t - (mem.watch_t or -CFG.quick_every) < CFG.quick_every then return end
  mem.watch_t = t
  local fp = fingerprint()
  if fp ~= mem.fp then
    local first = mem.fp == nil
    mem.fp = fp
    local done = check_pending(K)
    if not first then
      if t - (mem.quick_t or -CFG.quick_min) >= CFG.quick_min or done > 0 then
        mem.quick_t = t
        due('quick', t, 'change')
      else
        due('quick', (mem.quick_t or t) + CFG.quick_min, 'change')
      end
      -- FR-54: the seal after a construction change: at once while sealed (a broken seal is the news), else daily
      local s = mem.seal
      if s and (s.sealed or t - (mem.seal_ct or -DAY) >= DAY) then
        mem.seal_ct = t
        due('seal', t + CFG.lever_delay, 'construction')
      end
    end
  elseif mem.npend > 0 and t - (mem.pend_t or 0) >= DAY then
    mem.pend_t = t
    check_pending(K)
  end
end

---------------------------------------------------------------- jobs
local JOBS = {
  audit = function(K, d) job_audit(K, d.why) end,
  quick = function(K) job_quick(K) end,
  seal = function(K, d) job_seal(K, d.why) end,
  perim = function(K, d) job_perim(K, d.why) end,
  items = function(K, d) job_items(K, d.why) end,
  edges = function(K) job_edges(K) end,
  scan = function(K, d) job_scan(K, d.arg == true) end,
  paint = function(K) job_paint(K) end,
}

local function schedule_periodic(K, t)
  local mode = K.mode()
  local peace = mode == 'PEACE'
  local function per(name, last, every, why)
    if not mem.run[name] and t - (last or -every) >= every then due(name, t, why or 'periodic') end
  end
  per('audit', mem.last_audit, peace and CFG.audit_every or CFG.audit_alert)
  if mem.items then per('items', mem.items.seen, peace and CFG.items_every or CFG.items_alert) end
  per('seal', mem.seal and mem.seal.tick, CFG.seal_every)
  per('edges', mem.edges and mem.edges.tick, CFG.edges_every)
  per('scan', mem.scan and mem.scan.tick, CFG.scan_every)
  if peace and t - (mem.retire_t or -CFG.seal_every) >= CFG.seal_every then
    mem.retire_t = t
    due('perim', t, 'retire')
  end
end

-- urgent jobs run at CFG.rate_urgent and before every background job: a lever pull, a siege, a construction outside
-- PEACE, perimeter.record, a CUTOFF re-check, a mode change, the first result after a load
local URGENT_SEAL = {lever = true, siege = true, record = true, inspect = true}
local function urgent(K, name, d)
  if name == 'quick' then return true end
  if (name == 'edges' and not mem.edges) or (name == 'audit' and not mem.reach) or (name == 'scan' and not mem.scan)
     or (name == 'seal' and not mem.seal) then return true end
  local why = d and d.why or ''
  if name == 'seal' then return URGENT_SEAL[why] == true or (why == 'construction' and K.mode() ~= 'PEACE') end
  if name == 'perim' then return why == 'pre' or why == 'post' end
  if name == 'audit' then
    return why:find('^quick') ~= nil or why:find('^mode') ~= nil or why:find('^before') ~= nil
  end
  return false
end

-- the job to run now: a running (parked) or due one, urgent ones first, then by ORDER. An urgent request replaces a
-- background run of the same job (its answer is stale: a lever moved, a CUTOFF re-check asks); jobs commit only at
-- their end, so a dropped run leaves nothing half done.
local function pick(K, t)
  local bg, bgd
  for _, name in ipairs(ORDER) do
    local r = mem.run[name]
    local dd = mem.due[name]
    if dd and dd.tick > t then dd = nil end
    if r and dd and not urgent(K, name, r.d) and urgent(K, name, dd) then
      mem.run[name] = nil
      mem.stats.dropped = (mem.stats.dropped or 0) + 1
      r = nil
    end
    local d = r and r.d or dd
    if d then
      if urgent(K, name, d) then return name, d, true end
      if not bg then bg, bgd = name, d end
    end
  end
  return bg, bgd, false
end

-- FR-62: the work bucket, refilled in real time (K.now().ms), at most CFG.work units; a slice overrun is a debt
local function refill(K, u)
  local ms = K.now().ms or 0
  local last = mem.bucket_ms or ms
  mem.bucket_ms = ms
  local dt = math.max(0, math.min(ms - last, 1000))
  mem.bucket = math.min(CFG.work, (mem.bucket or CFG.work) + (u and CFG.rate_urgent or CFG.rate) * dt / 1000)
end

local function run_jobs(K, t)
  local name, d, u = pick(K, t)
  if not name then return nil end
  refill(K, u)
  if mem.bucket < (u and 1 or CFG.min_slice) then return u and 'more' or nil end
  mem.left = mem.bucket
  while mem.left > 0 do
    local nu
    name, d, nu = pick(K, t)
    if not name or (u and not nu) then break end  -- an urgent slice is not spent on background work
    local r = mem.run[name]
    if not r then
      mem.due[name] = nil
      local dd = d
      r = {d = dd, co = coroutine.create(function() JOBS[name](K, dd) end)}
      mem.run[name] = r
      mem.stats[name] = (mem.stats[name] or 0) + 1
    end
    local ok, err = coroutine.resume(r.co)
    if not ok then
      mem.run[name] = nil
      error('seal job ' .. tostring(name) .. ': ' .. tostring(err), 0)
    end
    if coroutine.status(r.co) == 'dead' then mem.run[name] = nil
    else break end                                -- out of work units for this frame
  end
  mem.bucket = mem.left
  name, d, u = pick(K, t)
  if not name then return nil end
  if u or mem.bucket >= CFG.min_slice then return 'more' end
  return nil
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.seal')
  p = type(p) == 'table' and p or {}
  st = {v = 2, perim = {}, cut = {}, req = {}, open = {}, hostile = int(p.hostile), painted = int(p.painted),
        flag_sig = type(p.flag_sig) == 'string' and p.flag_sig or nil}
  for k, piece in pairs(type(p.perim) == 'table' and p.perim or {}) do
    if type(k) == 'string' and type(piece) == 'table' and type(piece.k) == 'string' then st.perim[k] = piece end
  end
  for _, cls in ipairs(VITAL) do st.cut[cls] = int(type(p.cut) == 'table' and p.cut[cls]) or 0 end
  for k, v in pairs(type(p.req) == 'table' and p.req or {}) do if int(v) then st.req[k] = int(v) end end
  if type(p.swap) == 'table' and int(p.swap.since) then st.swap = {since = int(p.swap.since)} end
  if type(p.seal) == 'table' then st.seal = p.seal end
  for _, o in ipairs(type(p.open) == 'table' and p.open or {}) do
    if type(o) == 'table' and #o == 6 and #st.open < CFG.routes_max then
      local ok = true
      for i = 1, 6 do if not int(o[i]) then ok = false end end
      if ok then st.open[#st.open + 1] = {o[1], o[2], o[3], o[4], o[5], o[6]} end
    end
  end
  mem = {tt = {}, due = {}, run = {}, pend = {}, npend = 0, fresh = {}, done_info = {}, left = 0, bsize = {},
         stats = {}}
  local e = p.edges
  if type(e) == 'table' and int(e.t) and type(e.k) == 'table' then
    local list = {}
    for _, k in ipairs(e.k) do if int(k) and #list < CFG.edges_max then list[#list + 1] = int(k) end end
    mem.edges = {tick = int(e.t), list = list}
    st.edges = {t = int(e.t), k = list}
  end
  perim_count()
  dirty = true
  local t = now_t(K)
  if not mem.edges then due('edges', t, 'boot') end
  due('audit', t, 'boot')
  publish(K)
  save(K)
end

function M.step(K, budget, ctx)
  local t = now_t(K)
  if not (ctx and ctx.cont) then
    watch(K, t)
    schedule_periodic(K, t)
  end
  local r = run_jobs(K, t)
  if not next(mem.run) then publish(K) end
  save(K)
  return r
end

function M.state(K) return mem and mem.pub and {alert = mem.pub} or {} end

M.on.MODE = function(K, ev)
  local t = ev.tick or now_t(K)
  local to, from = ev.to, ev.from
  if to ~= 'PEACE' and from == 'PEACE' then
    due('audit', t, 'mode ' .. to)                      -- a fresh refuge audit ...
    if mem.items then due('items', t, 'mode') end       -- ... and stock counts behind it
  end
  if (to == 'SIEGE' or to == 'BREACH') and from ~= 'SIEGE' and from ~= 'BREACH' and from ~= 'RECOVERY' then
    due('perim', t, 'pre')
  end
  if to == 'RECOVERY' then
    due('perim', t + CFG.lever_delay, 'post')
    due('seal', t + CFG.lever_delay, 'siege')
  end
  if to == 'PEACE' and st.swap then st.swap, dirty = nil, true end
  publish(K)
  save(K)
end
M.on['EV:SIEGE_END'] = function(K, ev)
  local t = now_t(K)
  due('perim', t, 'post')
  due('seal', t, 'siege')
end
M.on['EV:GATE'] = function(K, ev)
  local s = type(ev.d) == 'table' and ev.d.state
  if s == 'up' or s == 'down' then due('seal', now_t(K) + CFG.lever_delay, 'lever') end
end
M.on['EV:PROJECT_STAGE'] = function(K, ev)
  local d = type(ev.d) == 'table' and ev.d or {}
  if d.defense == 1 then due('seal', now_t(K), 'construction') end
end
M.on['EV:PROJECT_DONE'] = function(K)
  local t = now_t(K)
  due('scan', math.max(t, (mem.scan and mem.scan.tick or -CFG.scan_min) + CFG.scan_min), 'project')
end
M.on.UNLOAD = function(K) save(K) end

-- verb perimeter.record {} (FR-60): the next entrance check (urgent) records the perimeter: the pieces around every
-- known opening that is sealed now and, on a sealed fort, the closers on the boundary of the citizens' main group
M.verbs['perimeter.record'] = function(K, args, cmd)
  mem.rec_n = (mem.rec_n or 0) + 1
  mem.rec_req = mem.rec_n                         -- a request number: a run that started before it keeps it
  due('seal', now_t(K), 'record')
  local n, no = mem.perim_n or 0, #(st.open or {})
  return true, string.format('queued: the next entrance check records the perimeter (%d pieces, %d known openings); '
                             .. 'inspect perimeter shows the result', n, no), {queued = 1, n = n, open = no}
end

---------------------------------------------------------------- inspect (kern routes inspect what=<name> here)
local function pairs_of(t, n)
  local r = {}
  for _, g in ipairs(sorted_keys(t)) do
    if #r >= (n or 6) then break end
    r[#r + 1] = {g, t[g]}
  end
  return r
end

-- run a job synchronously (inspect on a fresh boot): no yields, unlimited budget
local function sync(fn, ...)
  local left = mem.left
  mem.left = math.huge
  local ok, err = pcall(fn, ...)
  mem.left = left
  if not ok then error(err, 0) end
end

-- `key:'refresh'`: the item census and the audit again, now (FR-59: what the stockpiles hold this minute)
local function refresh_audit(K)
  if mem.run.audit then return end
  if not mem.run.items then sync(job_items, K, 'inspect', true) end
  sync(job_audit, K, 'inspect')
end

M.inspect.reach = function(K, args)
  local t = now_t(K)
  if not mem.reach then
    if not mem.run.audit then sync(job_audit, K, 'inspect') end
  elseif args.key == 'refresh' then refresh_audit(K) end
  local R = mem.reach
  if not R then return true, 'reach: the first audit is running', {tick = t} end
  local cls = {}
  for _, c in ipairs(CLASSES) do
    local C = R.cls[c]
    local on = R.main and C.by[R.main] or 0
    local at
    for g, p in pairs(C.at) do if g ~= R.main and not at then at = {g, p[1], p[2], p[3]} end end
    cls[c] = {n = C.n, main = on, off = C.n - on, groups = pairs_of(C.by), off_at = at}
  end
  -- FR-63: the stairs read now, not from the scan
  local dead
  sync(function() dead = live_stairs() end)
  local flags = {}
  for _, f in ipairs(R.flags) do if f:sub(1, 7) ~= 'stairs:' then flags[#flags + 1] = f end end
  local sf = stairs_flag(dead)
  if sf then flags[#flags + 1] = sf end
  local stairs = {}
  for i, s in ipairs(dead) do
    if i > 12 then break end
    stairs[i] = {s[1], s[2], s[3], s[4], s[5]}
  end
  local runs, busy = {}, {}
  for k, v in pairs(mem.stats) do runs[k] = v end
  for _, name in ipairs(ORDER) do if mem.run[name] then busy[#busy + 1] = name end end
  return true, string.format('reach %s (age %d): %s', R.main and ('main group ' .. R.main) or 'no citizens',
         t - R.tick, #flags > 0 and flags[1] or 'every class on the citizens\' group'),
         {tick = R.tick, main = R.main or 0, cit = {n = R.cit.n, groups = pairs_of(R.cit.by)}, classes = cls,
          cut = R.cut, flags = flags, stairs = stairs, blame = R.blame, items = R.items,
          scan = mem.scan and {tick = mem.scan.tick, n = mem.scan.n, partial = mem.scan.partial and 1 or 0} or nil,
          edges = mem.edges and {tick = mem.edges.tick, n = #mem.edges.list} or nil, runs = runs, busy = busy}
end

M.inspect.entrances = function(K, args)
  if not mem.seal or args.key == 'refresh' then
    if not mem.run.seal then sync(job_seal, K, 'inspect') end
  end
  local s = mem.seal
  if not s then return true, 'entrances: the first check is running', {} end
  return true, s.msg or '?', {tick = s.tick, why = s.why, sealed = s.sealed, routes = s.routes, first = s.first,
                              openings = s.openings, edge = s.edge, len = s.len, via = s.via, partial = s.partial,
                              expect_sealed = s.expect, bfs = s.bfs, reused = s.reused and 1 or 0,
                              closed = s.closed}
end

M.inspect.defense = function(K)
  local man = K.manifest()
  local names = {}
  for _, n in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[n]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 then names[#names + 1] = n end
  end
  -- levers and what they are linked to (lever.lua:24-27)
  local levers = {}
  local tv = vec('buildings', 'TRAP')
  for i = 0, vlen(tv) - 1 do
    local lv = tv[i]
    local okl, isl = pcall(function() return lv.trap_type == df.trap_type.Lever end)
    if lv and okl and isl then
      local tg = {}
      pcall(function()
        for _, m in ipairs(lv.linked_mechanisms) do
          local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
          local tb = ref and ref:getBuilding()
          if tb then tg[tb.id] = true end
        end
      end)
      local job
      pcall(function()
        for _, j in ipairs(lv.jobs) do if j.job_type == df.job_type.PullLever then job = j.id end end
      end)
      levers[#levers + 1] = {id = lv.id, pos = {lv.centerx, lv.centery, lv.z}, targets = tg, job = job}
    end
  end
  local out = {}
  local bv = vec('buildings', 'BRIDGE')
  for i = 0, math.min(vlen(bv), 16) - 1 do
    local b = bv[i]
    if b then
      local fp = {b.x1, b.y1, b.z, b.x2, b.y2, b.z}
      local name
      for _, n in ipairs(names) do
        local m = man.bridges[n].fp
        if m[3] == b.z and m[1] <= b.x2 and m[4] >= b.x1 and m[2] <= b.y2 and m[5] >= b.y1 then name = n end
      end
      local _, s = bstate(b)
      local raw = {}
      for _, f in ipairs({'raised', 'closed', 'raising', 'lowering', 'closing', 'opening'}) do
        local v = gflag(b, f)
        if v ~= nil then raw[f] = v and 1 or 0 end
      end
      local fpg, sides = {}, {}
      for x = fp[1] - 1, fp[4] + 1 do
        for y = fp[2] - 1, fp[5] + 1 do
          local g = grp(x, y, fp[3])
          if x >= fp[1] and x <= fp[4] and y >= fp[2] and y <= fp[5] then
            if g then fpg[g] = true end
          elseif g and g ~= 0 then sides[g] = true end
        end
      end
      local ns = #sorted_keys(sides)
      local through
      if ns == 0 then through = 'unknown'
      elseif ns >= 2 then through = 'cut'
      elseif s == 'up' then through = 'bypass'          -- raised, yet both sides are one walk group
      else through = 'open' end
      local lv = {}
      for _, l in ipairs(levers) do
        if l.targets[b.id] then lv[#lv + 1] = {id = l.id, pos = l.pos, linked = 1, pull = l.job} end
      end
      if name then
        for _, p in ipairs(man.bridges[name].levers or {}) do
          local found = false
          for _, l in ipairs(lv) do
            if l.pos[1] == p[1] and l.pos[2] == p[2] and l.pos[3] == p[3] then found = true end
          end
          if not found then
            local here
            for _, l in ipairs(levers) do
              if l.pos[1] == p[1] and l.pos[2] == p[2] and l.pos[3] == p[3] then here = l end
            end
            lv[#lv + 1] = {id = here and here.id or -1, pos = {p[1], p[2], p[3]}, linked = 0,
                           why = here and 'not linked to this bridge' or 'no lever built'}
          end
        end
      end
      local fpl = {}
      for g in pairs(fpg) do fpl[#fpl + 1] = g end
      table.sort(fpl)
      out[#out + 1] = {name = name or ('#' .. b.id), id = b.id, fp = fp, state = s, gate_flags = raw,
                       walk = {footprint = fpl, sides = sorted_keys(sides), through = through}, levers = lv}
    end
  end
  for _, n in ipairs(names) do
    local seen = false
    for _, o in ipairs(out) do if o.name == n then seen = true end end
    if not seen then out[#out + 1] = {name = n, fp = man.bridges[n].fp, state = 'missing'} end
  end
  local parts = {}
  for _, o in ipairs(out) do
    local nl = 0
    for _, l in ipairs(o.levers or {}) do if l.linked == 1 then nl = nl + 1 end end
    parts[#parts + 1] = string.format('%s %s/%s %dlev', o.name, o.state, o.walk and o.walk.through or '-', nl)
  end
  return true, trunc(#out > 0 and table.concat(parts, ', ') or 'no bridges', 300), {bridges = out}
end

M.inspect.perimeter = function(K, args)
  local by, list = {}, {}
  for _, k in ipairs(sorted_keys(st.perim)) do
    local p = st.perim[k]
    by[p.k] = (by[p.k] or 0) + 1
    if #list < 60 then list[#list + 1] = {k, p.k, p.src or ''} end
  end
  local d = mem.perim_diff
  local queued = mem.rec_req ~= nil
  return true, string.format('%d perimeter pieces%s', mem.perim_n or 0, queued and ' (recording queued)' or ''),
         {n = mem.perim_n or 0, by = by, pieces = list, open = #(st.open or {}), rec = mem.rec,
          queued = queued and 1 or 0,
          diff = d and {tick = d.tick, why = d.why, gone = {table.unpack(d.gone, 1, math.min(#d.gone, 40))}} or nil}
end

M.inspect.refuge = function(K, args)
  if not mem.audit then
    if not mem.run.audit then sync(job_audit, K, 'inspect') end
  elseif args.key == 'refresh' then refresh_audit(K) end
  local au = mem.audit
  if not au then return true, 'refuge: the first audit is running', {} end
  local b = {}
  for name, a in pairs(au.burrows) do
    b[name] = {exists = a.exists and 1 or 0, tiles = a.tiles, inside = a.inside, drink = a.drink, food = a.food,
               beds = a.beds, wells = a.wells, ok = a.ok and 1 or 0, why = a.why}
  end
  local choice = {}
  for _, m in ipairs({'ALERT', 'SIEGE', 'BREACH', 'RECOVERY'}) do
    local pick, want = choose(K, m, nil)
    choice[m] = {want = want, burrow = pick or ''}
  end
  publish(K)
  local p = mem.pub
  return true, string.format('alert %s: %s, %d tiles, %d/%d inside%s', K.mode(),
                             p.burrow ~= '' and p.burrow or 'no confinement',
         p.tiles, p.inside, au.cit, p.why ~= '' and (' (' .. p.why .. ')') or ''),
         {tick = au.tick, cit = au.cit, burrows = b, choice = choice, swap = st.swap,
          quiet = quiet(K) == math.huge and -1 or quiet(K)}
end

return M
