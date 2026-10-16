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
--             when its answer can change. BUG-012: the doors of each opening (a door on it, the first door on its
--             route toward the citizens, the doors a few steps inside it) for the reflex lockdown (entrance_doors)
--   perimeter (FR-56/60) walls, doors, gates and killbox tiles of defense projects, of the manifest and of the
--             inside/outside boundary (learned by the BFS in PEACE), plus (FR-60, forts without a manifest) every
--             wall, door, gate or bridge around an opening the entrance check finds sealed, and on the verb
--             perimeter.record the closers on the boundary of the citizens' group; persisted in m.seal. After an
--             episode (a siege, an ALERT, a reflex lockdown: see `episode`) they are compared with the map, lost pieces
--             re-queued (runner.repair) and PERIMETER_BROKEN (A) raised; a piece already gone in PEACE or when an
--             episode begins is retired, never rebuilt
--   defense   (FR-24) every bridge's real gate_flags, the walk groups on its sides and its levers' links
--   refuge    (FR-33/37/57) burrow audits (tiles, citizens inside, drink, food, beds) and alert_burrow(mode): the
--             civ-alert burrow siege uses. Kern+ normally, the refuge (Tiefe+) in BREACH and until CFG.back_days
--             quiet days, never a burrow without drink and food for the population: the fallback is the
--             interior burrow (CFG.interior, painted from revealed walkable inside tiles of the citizens' group),
--             else no confinement at all; REFUGE_FAIL (A) says so. Beds (beds >= ceil(citizens x bed_pct / 100))
--             only rank: a burrow short of them is taken when none has enough. BUG-011: while a reflex lockdown holds
--             the alert (hold), the interior burrow is kept even when it fails on supplies (it holds whatever the fort
--             has inside; the lockdown keeps citizens off the surface), and a missing one is painted at once. BUG-013:
--             the lever burrow (CFG.levers) with the tiles of gate's linked levers, listed in the alert while a pull
--             is pending (lever_burrow)
--             BUG-018 (the first real siege: 50 -> 1, the alert held everybody in the halls the goblins walked into):
--             a burrow is confined to only when it is separated: no opening of the entrance BFS reaches it without a
--             door, hatch, bridge or floodgate (the exposure flood after every entrance BFS; a porch of at most
--             CFG.porch_max tiles behind an opening exposes nothing) and no visible hostile stands in it.
--             BUG-019/FR-67: two levels, SIEGE (separated, drink, food, beds) and BREACH (separated and reachable, no
--             counts, for CFG.breach_days). The dead end behind the deepest stair (scan) is painted as the refuge when
--             it is missing (burrows screen); it is the last fallback when an opening reaches every other burrow, at
--             least CFG.dead_gap steps from them. Nothing usable while an opening reaches the burrows: no confinement,
--             the alert goes off even in a lockdown and the citizens flee on their own (REFUGE_FAIL says so)
--   siege's supply rules (BUG-028): groups() (citizens, stock and hostile groups read in one go), sides(fp) (the groups
--             around a bridge), split(list) (what raising bridges together would cut apart: a flood per side, sliced,
--             urgent outside PEACE); SUPPLY_OUTSIDE (A) when most of the drink or food lies outside Kern+/the refuge
-- Cost (FR-62): work runs in coroutines; a work unit is about one DF read (tile flags, walk group, tiletype, burrow
-- test, the fields of one item). A token bucket refilled in real time caps the units per second (CFG.rate, or
-- CFG.rate_urgent while an urgent job runs: a lever pull, a siege, a CUTOFF re-check, perimeter.record, the first
-- result after a load) and CFG.work caps one frame; an urgent job pre-empts a background one, which resumes later.
-- The map edge keeps one tile per walkable run, the stairs and interior come from a flood over the citizens' groups
-- (not a box over hidden rock), burrow sizes are cached and a periodic audit with unchanged inputs is skipped.
-- BUG-026: a background job waits while another module holds a busy kernel boost (K.busy(): trade with the trade screen
-- open); urgent jobs run as always.
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
  -- BUG-012 (Run 9: the door one tile behind the east stair was no "entrance door"): per opening, its first
  -- door_members entries are searched: the first door on the BFS route toward the citizens within door_route tiles,
  -- and every door within door_near steps over inside tiles (the walk stops at a door), door_walk tiles at most
  door_route = 12, door_near = 3, door_walk = 200, door_members = 8, doors_per = 6, doors_max = 32,
  rec_r = 1,                  -- FR-60: closers this far around a sealed opening's inside and outside tile
  pred_near = 25,             -- FR-33: a wild large predator counts only this close to an entrance (sense)
  back_days = 3,              -- FR-57: the refuge stays the confinement until this many days without a hostile
  min_tiles = 20, drink_per_cit = 1, food_per_cit = 1,   -- FR-37 burrow audit (per citizen)
  -- refuge beds (live Run 10: "Kern+ fails beds 18<23", 18 beds for about 90 citizens): beds >= ceil(citizens x
  -- bed_pct / 100), the share asleep at once; 0 = no bed count. A burrow short of beds is still taken when no burrow
  -- has enough (a dwarf without a bed sleeps on the floor: a bad thought; refusing the refuge sends everybody somewhere
  -- worse). config/reflex.json refuge.bed_pct
  bed_pct = 25,
  -- BUG-019/FR-67: the BREACH level (separated and reachable, no drink, food or bed counts) and the dead end hold for
  -- breach_days after the first such pick of an episode (a dwarf goes thirsty after about 20 days without a drink;
  -- config/reflex.json refuge.breach_days), on a burrow of breach_tiles tiles at least
  breach_days = 7, breach_tiles = 9,
  porch_max = 12,             -- BUG-018: an opening whose flood stops within this many tiles (a door behind it): closed
  -- FR-67: the dead end behind the deepest stair. A level above the deepest one joins it while it holds at most
  -- dead_level tiles (the deepest one dead_max), no citizen and no bed, and links only to the level below and to one
  -- place above; dead_gap = the fewest steps from an opening it may be when it is used unseparated
  dead_level = 400, dead_max = 2000, dead_gap = 10,
  -- BUG-028 (c): the flood that tells what a raise would cut apart: at most split_max tiles; its answer is used for
  -- split_age ticks while no bridge, door or construction changed
  split_max = 20000, split_age = 1200,
  -- BUG-028 (d): SUPPLY_OUTSIDE when more than sup_out_pct % of a stock (>= sup_min units) lies outside Kern+ and the
  -- refuge; the plan check wants sup_days days of drink and food inside
  sup_out_pct = 50, sup_min = 20, sup_days = 90,
  interior = 'Innen+',        -- the whole-interior burrow, painted when Kern+ fails its audit
  paint_chunk = 400, interior_max = 20000, repaint = 7 * DAY,
  levers = 'Hebel+',          -- BUG-013: the lever tiles gate's pulls need inside the civ alert (lever_burrow)
  lever_check = 100,          -- ticks its tiles are trusted before they are read again (the player may erase them)
  lever_retry = 600,          -- ticks before a refused paint is tried again
  levers_max = 64,
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
-- unchanged, up to CFG.bsize_stale (seal's own painting forgets it). Also up to 16 sample tiles spread over it (the
-- first one and every 64th; BUG-019: is the burrow reachable?) and the block count.
local function burrow_size(name, t)
  local blocks = block_list(name)
  spend(1)
  if not blocks then return 0, {}, 0 end
  local c = mem.bsize[name]
  if c and c.nb == #blocks and t - c.t < CFG.bsize_stale then return c.n, c.s or {}, c.nb end
  local n, s = 0, {}
  for i = 1, #blocks do
    local b = burrow(name)                                         -- never keep a DF pointer across frames
    local blk = b and blocks[i]
    if not blk then break end
    spend(1)
    local mp = blk.map_pos
    for x = 0, 15 do
      for y = 0, 15 do
        if dfhack.burrows.isAssignedBlockTile(b, blk, x, y) then
          n = n + 1
          if mp and #s < 16 and (n == 1 or n % 64 == 0) then s[#s + 1] = {mp.x + x, mp.y + y, mp.z} end
        end
      end
      spend(16)
    end
  end
  mem.bsize[name] = {nb = #blocks, n = n, t = t, s = s}
  return n, s, #blocks
end

local function in_burrow(b, x, y, z)
  P.x, P.y, P.z = x, y, z
  local ok, v = pcall(dfhack.burrows.isAssignedTile, b, P)
  return ok and v == true
end

---------------------------------------------------------------- scheduling
-- priority among urgent jobs, then among background ones
local ORDER = {'perim', 'seal', 'split', 'quick', 'audit', 'items', 'scan', 'paint', 'edges'}

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

-- the refuge knobs the player may set (config/reflex.json `refuge`, CONTRACTS §9.18); a bad value keeps the default
local function rcfg(K)
  local c = {bed_pct = CFG.bed_pct, breach_days = CFG.breach_days}
  local r = type(K.cfg) == 'table' and type(K.cfg.reflex) == 'table' and K.cfg.reflex.refuge or nil
  if type(r) == 'table' then
    local b, d = int(r.bed_pct), int(r.breach_days)
    if b and b >= 0 and b <= 100 then c.bed_pct = b end
    if d and d >= 0 and d <= 60 then c.breach_days = d end
  end
  return c
end

-- the SIEGE level's counts (FR-37): tiles >= max(min_tiles, citizens), drink >= citizens x drink_per_cit (or a well),
-- food >= citizens x food_per_cit; a.sup = they hold. Beds >= ceil(citizens x bed_pct / 100) (the share asleep at once,
-- 0 = none): a shortfall is a.bed_short and ranks the burrow below one with enough beds, never refuses it alone. a.why
-- lists every shortfall, the beds with their formula ('beds 18<23 (25% of 90 citizens)').
local function burrow_audit(K, ncit, a)
  local pct = rcfg(K).bed_pct
  local need = {tiles = math.max(CFG.min_tiles, ncit), drink = ncit * CFG.drink_per_cit,
                food = ncit * CFG.food_per_cit, beds = pct > 0 and math.max(1, (ncit * pct + 99) // 100) or 0}
  local why = {}
  a.sup, a.bed_short = false, false
  if not a.exists then why[1] = 'missing'
  else
    if a.tiles < need.tiles then why[#why + 1] = string.format('%d tiles<%d', a.tiles, need.tiles) end
    if a.drink < need.drink and a.wells == 0 then why[#why + 1] = string.format('drink %d<%d', a.drink, need.drink) end
    if a.food < need.food then why[#why + 1] = string.format('food %d<%d', a.food, need.food) end
    a.sup = #why == 0
    if a.beds < need.beds then
      a.bed_short = true
      why[#why + 1] = string.format('beds %d<%d (%d%% of %d citizens)', a.beds, need.beds, pct, ncit)
    end
  end
  a.ok = a.sup and not a.bed_short                       -- the counts in full (the rating adds the separation)
  a.room = a.exists and a.tiles >= need.tiles            -- BUG-011: big enough to be kept for a lockdown
  a.why = table.concat(why, ', ')
  return a, need, pct
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
    if B[n].exists then B[n].tiles, B[n].samples, B[n].nb = burrow_size(n, t0) end
  end
  -- BUG-019: reachable = a citizen inside, or a walkable sample tile on a citizen's walk group, both read now (one
  -- frame, one numbering, BUG-021); -1 = no walkable sample
  local now_g, nread = nil, 0
  for _, n in ipairs(names) do
    local a = B[n]
    if a.exists then
      a.reach = a.inside > 0 and 1 or -1
      for _, p in ipairs(a.inside == 0 and a.samples or {}) do
        now_g = now_g or group_counts(citizens(K))
        local g = grp(p[1], p[2], p[3])
        nread = nread + 1
        if g and g ~= 0 then
          if now_g[g] then a.reach = 1; break end
          a.reach = 0
        end
      end
    end
  end
  if now_g then spend(3 * #cits + 2 * nread) end
  local need, pct
  for _, n in ipairs(names) do _, need, pct = burrow_audit(K, #cits, B[n]) end
  R.need = {tiles = need.tiles, drink = need.drink, food = need.food, beds = need.beds, bed_pct = pct, cit = #cits}
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

-- the vital class that more citizens than before lost the group of (the biggest increase), or nil
local function cut_inc(cut)
  local inc
  for _, cls in ipairs(VITAL) do
    local d = cut[cls] - (int(st.cut[cls]) or 0)
    if d > 0 and (not inc or d > inc.d) then inc = {cls = cls, d = d} end
  end
  return inc
end

-- BUG-021 (Run 10: "19 citizens cut off from food: cause not found" while all 19 and the food stood on group 3302): DF
-- renumbers the walk groups while constructions run (3276 -> 3293 -> 3302 within minutes) and the audit read the
-- citizens frames before the stock tiles. A cut is confirmed on groups read now, in one go (no yield in between): the
-- citizens and one tile per walk group of each vital class (the audit's per-group tiles and the re-check tiles).
-- Returns the citizens, their groups, the main group and the class groups as read now.
local function reread_cut(K, R)
  local cits = citizens(K)
  local cg, main = group_counts(cits)
  local by, n = {}, 0
  for _, cls in ipairs(VITAL) do
    local s = {}
    for _, p in pairs(R.cls[cls].at) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then s[g] = true end
      n = n + 1
    end
    for _, p in ipairs(R.reps[cls] or {}) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then s[g] = true end
      n = n + 1
    end
    by[cls] = s
  end
  spend(3 * #cits + 2 * n)
  return cits, cg, main, by
end

-- a tile of class `cls` on a group in `has` (as read now), the main group's first: pos, group
local function class_tile(R, cls, has, main)
  local best, bg
  local function look(p)
    local g = grp(p[1], p[2], p[3])
    if g and has[g] and (not best or g == main) then best, bg = p, g end
    return best ~= nil and bg == main
  end
  for _, p in ipairs(R.reps[cls] or {}) do if look(p) then return best, bg end end
  for _, g in ipairs(sorted_keys(R.cls[cls].at)) do if look(R.cls[cls].at[g]) then return best, bg end end
  return best, bg
end

-- BUG-028 (d) (Run 10 y419: 3093 drink units lay in front of O1, on the goblins' side, 737 (60 days) in the core):
-- the drink and food inside the lockable core (Kern+ and the refuge) against the whole stock; the days inside scale
-- economy's stock days (state stock.drink_d/food_d) by that share. SUPPLY_OUTSIDE (A) when the main part of a class
-- (more than CFG.sup_out_pct) lies outside, once and again only with news (util/cadence, a game month and 30 min).
-- The days go to the state (alert.core_d/core_f) for the plan check (>= CFG.sup_days inside).
local function supply_check(K, R)
  local kern, refuge = R.names.kern, R.names.refuge
  local kb, rb = R.burrows[kern], R.burrows[refuge]
  if not (kb and kb.exists) then mem.core = nil; return end
  local v = K.view()
  local stock = type(v) == 'table' and type(v.stock) == 'table' and v.stock or {}
  local res, bad, toks = {}, {}, {}
  for _, e in ipairs({{'drink', 'drink_d'}, {'food', 'food_d'}}) do
    local cls, total = e[1], R.cls[e[1]].n
    local inside = math.min(total, kb[cls] + ((rb and rb.exists and refuge ~= kern) and rb[cls] or 0))
    local days = int(stock[e[2]])
    local c = {total = total, inside = inside, pct = total > 0 and (100 * inside // total) or 100,
               days = (days and total > 0) and math.min(9999, days * inside // total) or nil}
    res[cls] = c
    if total >= CFG.sup_min and 100 - c.pct > CFG.sup_out_pct then bad[#bad + 1] = cls; toks[#toks + 1] = cls end
  end
  mem.core = res
  local now = K.now()
  if #bad == 0 then
    if st.sup_rec and st.sup_rec.ids and #st.sup_rec.ids > 0 then st.sup_rec, dirty = CAD.quiet(st.sup_rec), true end
    return
  end
  if not CAD.due(st.sup_rec, now, bad, toks, {ticks = 28 * DAY, wall_s = 1800}) then return end
  st.sup_rec, dirty = CAD.mark(now, bad, toks), true
  local c = res[bad[1]]
  local core = kern .. ((rb and rb.exists and refuge ~= kern) and ('/' .. refuge) or '')
  local hint = string.format('keep >= %d days inside %s: %s', CFG.sup_days, core,
                             bad[1] == 'drink' and 'a still and a barrel stockpile in the core'
                             or 'a food stockpile (and the kitchen) in the core')
  K.emit('SUPPLY_OUTSIDE', 'A', trunc(string.format('%s: %d of %d (%d%%) outside %s, %s days inside: %s', bad[1],
         c.total - c.inside, c.total, 100 - c.pct, core, c.days and tostring(c.days) or '?', hint), 200),
         {cls = bad[1], inside = c.inside, total = c.total, pct = c.pct, days = c.days, want = CFG.sup_days,
          hint = trunc(hint, 120), also = #bad > 1 and bad[2] or nil})
end

local function commit_audit(K, R, cits)
  local t = now_t(K)
  local totals, by_cls = {}, {}
  for _, cls in ipairs(VITAL) do totals[cls] = R.cls[cls].n; by_cls[cls] = R.cls[cls].by end
  local cg, main = R.cit.by, R.main
  local cut = cut_of(cg, by_cls, totals)
  local dead = live_stairs()
  R.flags = reach_flags(R, dead)
  -- CUTOFF: more citizens than before lost the group of a vital class, confirmed on groups read now (BUG-021)
  local inc = cut_inc(cut)
  if inc then
    local seen = cut
    cits, cg, main, by_cls = reread_cut(K, R)
    cut = cut_of(cg, by_cls, totals)
    inc = cut_inc(cut)
    if not inc then
      mem.stats.cut_unconfirmed = (mem.stats.cut_unconfirmed or 0) + 1
      K.log('info', 'seal: CUTOFF not confirmed: the walk groups read now join the citizens and their %s ' ..
            '(audit read %d food, %d drink, %d bed cut; ids renumbered while it ran)',
            (cut_inc(seen) or {}).cls or '?', seen.food, seen.drink, seen.bed)
    end
  end
  R.cut = cut
  if inc then
    local gc, has = nil, {}
    for g, n in pairs(cg) do
      if not by_cls[inc.cls][g] and (not gc or n > cg[gc] or (n == cg[gc] and g < gc)) then gc = g end
    end
    for g in pairs(by_cls[inc.cls]) do has[g] = true end
    local cz
    for _, c in ipairs(cits) do if c.g == gc then cz = c; break end end
    local at, ag = class_tile(R, inc.cls, has, main)
    local b = blame(K, gc, has, cz and {cz.x, cz.y, cz.z})
    local n = cut[inc.cls]
    local what = b and string.format('%s at %d,%d,%d', b[4], b[1], b[2], b[3]) or 'cause not found'
    if b and b[5] then what = what .. ' (' .. b[5] .. ')' end
    -- BUG-021: who stands where: a cut-off citizen and his group, a stock tile of the class on another group (the main
    -- group's first)
    local where = (cz and string.format('; citizen %d at %d,%d,%d on group %d', cz.id, cz.x, cz.y, cz.z, gc) or '')
                  .. (at and string.format(', %s at %d,%d,%d on group %d', inc.cls, at[1], at[2], at[3], ag) or '')
    local d = {cls = inc.cls, n = n, grp = gc or 0, main = main or 0, why = trunc(b and b[4] or 'unknown', 60)}
    if b then d.pos = {b[1], b[2], b[3]} end
    if cz then d.unit, d.upos = cz.id, {cz.x, cz.y, cz.z} end
    if at then d.at, d.agrp = {at[1], at[2], at[3]}, ag end
    if b and b.bridge and GATED[K.mode()] then
      K.emit('SEAL', 'B', string.format('%d citizens shut out from %s by a raised bridge at %d,%d,%d', n, inc.cls,
             b[1], b[2], b[3]), {routes = 0, pos = d.pos, why = 'shut_out'})
    else
      K.emit('CUTOFF', 'A', trunc(string.format('%d citizens cut off from %s: %s%s', n, inc.cls, what, where), 200), d)
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
  mem.audit = {tick = t, burrows = R.burrows, names = R.names, cit = R.cit.n, need = R.need}
  supply_check(K, R)
  -- FR-33: Kern+ fails its audit (counts, or BUG-018: an opening reaches it) -> keep the whole-interior burrow ready
  local kb = R.burrows[R.names.kern]
  local ib = R.burrows[CFG.interior]
  local sp = mem.sepr
  local kexp = sp and not sp.sealed and sp.by[R.names.kern] and sp.by[R.names.kern].exp
  if kb and (not kb.ok or kexp) and R.main and (not ib or not ib.exists or not ib.ok)
     and t - (int(st.painted) or -CFG.repaint) >= CFG.repaint
     and t - (mem.paint_ask or -CFG.repaint) >= CFG.repaint then
    -- BUG-018: painted without the tiles an opening reaches, so it waits for the first exposure flood
    if sp then mem.paint_ask = t; due('scan', t, 'paint', true)
    else
      mem.paint_wait = true
      if not mem.run.seal then due('seal', t, 'refuge') end             -- a running check brings the flood itself
    end
  end
  -- BUG-018: a burrow painted or changed since the last exposure flood: the entrance check again (with its BFS)
  if sp and not sp.sealed then
    for _, n in ipairs(R.names and {R.names.kern, R.names.refuge, CFG.interior} or {}) do
      local a, e = R.burrows[n], sp.by[n]
      if a and a.exists and (not e or e.nb ~= a.nb) then due('seal', t, 'refuge'); break end
    end
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
      reps[#reps + 1] = {x = e.x, y = e.y, z = e.z, ox = e.ox, oy = e.oy, oz = e.oz, d = e.d, n = 1, m = {e}}
      at[r] = #reps
    else
      local c = reps[at[r]]
      c.n = c.n + 1
      if #c.m < CFG.door_members then c.m[#c.m + 1] = e end      -- BUG-012: the entries the door search starts from
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

---------------------------------------------------------------- entrance doors (BUG-012)
-- a built door or bridge on a revealed tile: the building, its type and its tile, else nil
local function door_at(k)
  local x, y, z = dec3(k)
  local des, occ = rev(x, y, z)
  spend(2)
  local b = des and bld_on(x, y, z, occ)
  local t = b and btype(b)
  if (t == 'Door' or t == 'Bridge') and built(b) then return b, t, x, y, z end
end

-- the doors that close one opening (a routes_of rep with its member entries r.m), from the BFS B over walk group G:
-- a door on an entry's inside or outside tile, the first door on the BFS route from each entry toward the citizens
-- (B.par, at most CFG.door_route tiles, inside tiles only) and every door within CFG.door_near steps of an entry over
-- inside tiles of G; that walk stops at a door, so it finds the door one or two tiles behind a stair or ramp
-- opening (Run 9: the east stair at 75,70,117 and its door at 74,70,117) and not the rooms beyond it. When the
-- opening has a door, the walk goes on past CFG.door_near (still stopping at doors, CFG.door_walk tiles at most): the
-- tiles it reached are the porch, the inside between the opening and its doors, where a citizen is still outside them
-- (the lockdown waits for him before it forbids them). Revealed tiles only. Returns {{id, x, y, z}} (at most
-- CFG.doors_per), whether a bridge stands on the opening or on that route before any door (the gates close it: no
-- "partial lockdown" for it), and the porch {key = true} (nil without doors).
local function opening_doors(B, G, r)
  local found, list, inside_c, nb, gated = {}, {}, {}, {}, false
  -- a door: listed (if `keep`), true; a bridge: true on the route (it closes it)
  local function take(k, route, keep)
    local b, t, x, y, z = door_at(k)
    if not b then return false end
    if t == 'Bridge' then
      if route then gated = true end
      return route == true
    end
    if keep ~= false and not found[b.id] and #list < CFG.doors_per then
      found[b.id] = true
      list[#list + 1] = {b.id, x, y, z}
    end
    return true
  end
  local function inside(k)                  -- a revealed inside tile of G (the BFS's own answer when it has one)
    local o = B.outs[k]
    if o == nil then
      o = inside_c[k]
      if o == nil then
        local x, y, z = dec3(k)
        local des = rev(x, y, z)
        spend(2)
        if des and not des.outside then
          P.x, P.y, P.z = x, y, z
          o = (dfhack.maps.getWalkableGroup(P) or 0) == G and 0 or false
        else o = false end
        inside_c[k] = o
      end
    end
    return o == 0
  end
  local d, q = {}, {}
  for _, e in ipairs(r.m or {}) do
    local ik = key3(e.x, e.y, e.z)
    take(key3(e.ox, e.oy, e.oz), true)
    -- the route inward (the BFS tree leads from every entry to the nearest citizen or stock tile)
    local k, n = ik, 0
    while k and k ~= -1 and n <= CFG.door_route and inside(k) do
      if take(k, true) then break end
      k, n = B.par[k], n + 1
    end
    if d[ik] == nil then d[ik] = 0; q[#q + 1] = ik end
  end
  -- the doors near the opening and its porch: one walk from all its entries (breadth first), at most CFG.door_walk
  -- tiles; past CFG.door_near steps only for an opening that has a door
  local porch, rim, head = {}, {}, 1
  local function expand(ck)
    local x, y, z = dec3(ck)
    local cnt = steps(x, y, z, nb)
    for i = 1, cnt do
      local nk = nb[i]
      if d[nk] == nil and not inside(nk) and i <= 8 and ramp_top(nk) then nk = nk - 16777216 end   -- down a ramp
      if d[nk] == nil and inside(nk) then d[nk] = d[ck] + 1; q[#q + 1] = nk end
    end
    spend(2)
  end
  while head <= #q and head <= CFG.door_walk do
    local ck = q[head]
    head = head + 1
    if not take(ck, nil, d[ck] <= CFG.door_near) then        -- a door ends the walk there
      porch[ck] = true
      if d[ck] == CFG.door_near then rim[#rim + 1] = ck else expand(ck) end
    end
    if head > #q and #rim > 0 then                            -- the near doors are known: the porch beyond them
      if #list > 0 then for _, rk in ipairs(rim) do expand(rk) end end
      rim = {}
    end
  end
  return list, gated, #list > 0 and porch or nil
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

---------------------------------------------------------------- refuge separation (BUG-018)
-- a tile an attacker cannot walk through although DF's walk groups join both sides: a built door, hatch, bridge (the
-- gates raise it), floodgate, grate or bars on a revealed tile (walls split the walk groups already)
local function sep_closer(k)
  local x, y, z = dec3(k)
  local des, occ = rev(x, y, z)
  spend(2)
  local b = des and bld_on(x, y, z, occ)
  if not b then return false end
  local kind = BKIND[btype(b) or '']
  return kind ~= nil and kind ~= 'statue' and built(b)
end

local function bkey(x, y, z) return (z * 256 + y // 16) * 256 + x // 16 end

-- BUG-018 (Run 9: `Kern+ ok:1` while three open entrances led into it): which audited burrows the openings of the
-- entrance BFS just run reach without passing a closer. A flood from the inside tile of every opening that has no gate
-- on it (opening_doors: a bridge on it or on its route inward; the gates raise it) over the inside tiles of the BFS's
-- walk group as the BFS read them (B.outs: no walk group is read again), stopping at closers; floods that meet are one
-- component. A component of at most CFG.porch_max tiles is a porch (a door stands right behind the opening) and
-- exposes nothing. Per burrow: the exposed tiles, the openings that reach it, the fewest steps from one of them. The
-- cost is the exposed part of the interior (a well sealed fort: its porches), in the seal job's slices.
local function expose(K, B, reps, res)
  local t0 = now_t(K)
  local nms = {}
  for _, n in ipairs((audit_names(K))) do
    local blocks = block_list(n)
    spend(1)
    if blocks then
      local bs = {}
      for i = 1, #blocks do
        local mp = blocks[i] and blocks[i].map_pos
        if mp then bs[bkey(mp.x, mp.y, mp.z)] = true end
      end
      spend(#blocks // 8 + 1)
      nms[#nms + 1] = {n = n, bs = bs, nb = #blocks, hit = {}, dmin = {}}
    end
  end
  local lab, dep, cl, q, head = {}, {}, {}, {}, 1          -- tile -> opening (-1 a closer), steps, closer?, queue
  local par, size, open = {}, {}, {}
  local function find(i) while par[i] ~= i do par[i] = par[par[i]]; i = par[i] end; return i end
  local function closer(k)
    local c = cl[k]
    if c == nil then c = sep_closer(k); cl[k] = c end
    return c
  end
  for i, r in ipairs(reps or {}) do
    par[i], size[i] = i, 0
    local o = res.openings[i]
    if not (o and o.gate == 1) then
      open[i] = {pos = {r.x, r.y, r.z}, kind = o and tostring(o.bld) or '?'}
      for _, e in ipairs(r.m or {}) do
        local ik = key3(e.x, e.y, e.z)
        if lab[ik] == nil and B.outs[ik] == 0 and not closer(ik) and not closer(key3(e.ox, e.oy, e.oz)) then
          lab[ik], dep[ik] = i, 0
          q[#q + 1] = ik
        end
      end
    end
  end
  local nb, rtop, partial, fr = {}, {}, false, nil
  while head <= #q do
    if head > CFG.bfs_max then partial = true; break end
    if fr ~= mem.fr then                                  -- a new frame: never keep a DF pointer across frames
      fr = mem.fr
      for _, nm in ipairs(nms) do nm.b = burrow(nm.n) end
    end
    local k = q[head]
    head = head + 1
    local li, d = lab[k], dep[k]
    size[li] = size[li] + 1
    local x, y, z = dec3(k)
    local bk = bkey(x, y, z)
    for _, nm in ipairs(nms) do
      if nm.bs[bk] and nm.b then                         -- a tile of one of the burrow's blocks: the tile test
        spend(1)
        if in_burrow(nm.b, x, y, z) then
          nm.hit[li] = (nm.hit[li] or 0) + 1
          if not nm.dmin[li] then nm.dmin[li] = d end
        end
      end
    end
    local n = steps(x, y, z, nb)
    for i = 1, n do
      local nk = nb[i]
      local o = B.outs[nk]
      if o == false and i <= 8 then                       -- down a ramp: the open top of a ramp one level down
        if rtop[nk] == nil then rtop[nk] = ramp_top(nk); spend(2) end
        if rtop[nk] then nk = nk - 16777216; o = B.outs[nk] end
      end
      if o == 0 then
        local l2 = lab[nk]
        if l2 == nil then
          if closer(nk) then lab[nk] = -1
          else lab[nk], dep[nk] = li, d + 1; q[#q + 1] = nk end
        elseif l2 > 0 and l2 ~= li then
          local a, b = find(li), find(l2)
          if a ~= b then par[b] = a end
        end
      end
    end
    spend(3)
  end
  local csize, big = {}, {}
  for i, c in pairs(size) do local r = find(i); csize[r] = (csize[r] or 0) + c end
  for i in pairs(size) do if (csize[find(i)] or 0) > CFG.porch_max then big[i] = true end end
  local by = {}
  for _, nm in ipairs(nms) do
    local n, d, roots = 0, nil, {}
    for li, c in pairs(nm.hit) do
      if big[li] then
        n = n + c
        if not d or nm.dmin[li] < d then d = nm.dmin[li] end
        roots[find(li)] = true
      end
    end
    local e = {exp = n > 0, n = n, d = d, nb = nm.nb}
    if n > 0 then
      local l, nr = {}, 0
      for i = 1, #(reps or {}) do
        if open[i] and big[i] and roots[find(i)] then
          nr = nr + 1
          if #l < 8 then
            l[#l + 1] = string.format('%d,%d,%d %s', open[i].pos[1], open[i].pos[2], open[i].pos[3], open[i].kind)
          end
        end
      end
      e.open, e.routes = l, nr
      e.why = string.format('open to %d entrance%s %s%s (%d step%s)', nr, nr == 1 and '' or 's',
                            table.concat(l, '; ', 1, math.min(#l, 2)), nr > 2 and (' +' .. (nr - 2)) or '', d,
                            d == 1 and '' or 's')
    end
    by[nm.n] = e
  end
  mem.sepr = {tick = t0, sealed = false, partial = partial, n = head - 1, by = by, tiles = lab, big = big}
  mem.stats.expose = (mem.stats.expose or 0) + 1
end

-- an exposed tile of the last flood (a component bigger than a porch)
local function exposed(k)
  local s = mem.sepr
  local l = s and not s.sealed and s.tiles[k]
  return type(l) == 'number' and l > 0 and s.big[l] == true
end

-- the BFS runs when its answer can change; in PEACE the open gates (D-14) leak by design, so a periodic or a
-- construction check there re-uses the last answer unless a known opening closed or CFG.bfs_every passed
local BFS_WHY = {inspect = true, record = true, lever = true, siege = true, lockdown = true, refuge = true}

-- BUG-021: DF renumbers the walk groups while constructions run (live Run 10: 3276 -> 3293 -> 3302 within minutes); a
-- sliced job whose reads straddle a renumbering compares two numberings. True when the tiles the citizens stood on
-- (citizens(K)) still carry the groups read then (one flag and one group read per citizen; their moves do not matter)
local function same_groups(cits)
  for _, c in ipairs(cits) do
    if grp(c.x, c.y, c.z) ~= c.g then spend(2 * #cits); return false end
  end
  spend(2 * #cits)
  return true
end

local function seal_pass(K, why, last)
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
  if not last and not same_groups(cits) then return 'retry' end   -- the edge groups and the citizens': one numbering
  local leak = {}
  for _, g in ipairs(sorted_keys(cg)) do if E[g] then leak[#leak + 1] = g end end
  local mode = K.mode()
  local expect = bridges_expect_sealed(K)
  local prev = mem.seal
  local B, added, G, reps = nil, 0, nil, nil
  if #leak == 0 then
    res.sealed, res.msg = true, 'seal verified: no route'
  else
    G = leak[1]
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
      if not last and not same_groups(cits) then return 'retry' end  -- renumbered during the BFS: G meant another group
      res.bfs = t0
      reps = routes_of(B.entries)
      res.routes, res.partial, res.visited = #reps, B.partial, B.visited
      local all, dseen, door_ops, porches = {}, {}, {}, {}
      for i = 1, math.min(#reps, CFG.routes_max) do
        local r = reps[i]
        local bt, bs = describe_tile(r.x, r.y, r.z)
        local ot, os_ = describe_tile(r.ox, r.oy, r.oz)
        local doors, gated, porch = opening_doors(B, G, r)   -- BUG-012: {{id, x, y, z}}, a bridge on it, porch
        res.openings[i] = {pos = {r.x, r.y, r.z}, out = {r.ox, r.oy, r.oz}, n = r.n, d = r.d,
                           bld = bt, state = bs, out_bld = ot, out_state = os_, doors = doors,
                           gate = (gated or bt == 'Bridge' or ot == 'Bridge') and 1 or 0}
        for _, dr in ipairs(doors) do
          if not dseen[dr[1]] and #all < CFG.doors_max then dseen[dr[1]] = true; all[#all + 1] = dr end
          local ops = door_ops[dr[1]] or {}
          ops[i], door_ops[dr[1]] = true, ops
        end
        for k in pairs(porch or {}) do
          local ops = porches[k] or {}
          ops[i], porches[k] = true, ops
        end
      end
      res.doors = all
      -- runtime only (mem.seal is never persisted, inspect leaves them out): who stands outside which door
      res.door_ops, res.porch = door_ops, porches
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
  elseif why ~= 'inspect' and (not (why == 'periodic' or why == 'refuge' or res.reused) or not prev
                               or prev.sealed ~= res.sealed or prev.routes ~= res.routes) then
    K.emit('SEAL', 'B', trunc(res.msg, 200), {routes = res.routes, pos = pos, why = trunc(why, 40),
           sealed = res.sealed and 1 or 0})
  end
  st.seal = {t = t0, sealed = res.sealed and 1 or 0, routes = res.routes}
  if res.sealed then st.leak_rec = nil end
  dirty = true
  -- BUG-018: which burrows the openings reach, after the doors are published (the lockdown's doors never wait for it)
  if res.sealed then mem.sepr = {tick = t0, sealed = true, by = {}, tiles = {}, big = {}}
  elseif B then expose(K, B, reps, res) end
  if mem.paint_wait and mem.sepr then mem.paint_wait = nil; due('scan', t0, 'paint', true) end
end

-- the entrance check; a pass that saw the walk groups renumbered starts over (at most three passes, the last one
-- stands whatever it saw)
local function job_seal(K, why)
  for try = 1, 3 do
    if seal_pass(K, why, try == 3) ~= 'retry' then return end
    mem.stats.renum = (mem.stats.renum or 0) + 1
  end
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

-- FR-67 (BUG-019): the dead end behind the deepest stair, from the scan's flood over the citizens' main group (S.gk:
-- key -> walk group, S.out: outside, S.vs: stair and ramp shapes, S.rtop: open ramp tops, S.low: the deepest inside
-- tile). From the deepest level upward, one level component (8 neighbours on its z) at a time: a level joins while it
-- holds at most CFG.dead_level tiles (the deepest CFG.dead_max), no citizen and no bed, and links only to the level
-- below and to one component above (stairs, ramps); the first level that does not is the mouth, the fort side of the
-- stair (Run 9: the shaft 30,66 z80-107 below the halls on z108). How far the openings are from it is the rating's
-- business (dead_gap). Revealed tiles only (the flood read them). Returns {tiles = {keys}, n, bottom, mouth, z0, z1}
-- or {why = str}.
local function dead_end(K, main, S)
  if not S.low then return {why = 'no inside tile'} end
  local gk, out, vs, rtop = S.gk, S.out, S.vs, S.rtop
  local stop = {}
  for _, c in ipairs(S.cits) do stop[key3(c.x, c.y, c.z)] = true end
  local i = 0
  while true do
    local v = vec('buildings', 'BED')                      -- re-read after every yield
    if not v or i >= #v then break end
    local b = v[i]
    i = i + 1
    if b and int(b.centerx) then stop[key3(b.centerx, b.centery, b.z)] = true end
    spend(1)
  end
  local function inside(k) return gk[k] == main and not out[k] end
  local function level(k0, maxn)                           -- the component of k0 on its level, or nil and why
    local z = k0 // 16777216
    local list, set, h = {k0}, {[k0] = true}, 1
    while h <= #list do
      local k = list[h]
      h = h + 1
      if stop[k] then return nil, 'citizens or beds' end
      if #list > maxn then return nil, 'big' end
      local x, y = k % 4096, (k // 4096) % 4096
      for dy = -1, 1 do
        for dx = -1, 1 do
          local nk = key3(x + dx, y + dy, z)
          if (dx ~= 0 or dy ~= 0) and not set[nk] and inside(nk) then set[nk] = true; list[#list + 1] = nk end
        end
      end
      spend(1)
    end
    return list, set
  end
  local function links(list)                               -- the tiles a step up / down from the level reaches
    local ups, downs = {}, {}
    for _, k in ipairs(list) do
      local x, y, z = dec3(k)
      local sh = vs[k]
      local a, b = k + 16777216, k - 16777216              -- the tiles above and below
      if sh and UP[sh] and inside(a) and DOWN[vs[a] or ''] then ups[#ups + 1] = a end
      if sh and DOWN[sh] and inside(b) and UP[vs[b] or ''] then downs[#downs + 1] = b end
      for dy = -1, 1 do
        for dx = -1, 1 do
          if dx ~= 0 or dy ~= 0 then
            local up = key3(x + dx, y + dy, z + 1)
            if sh == 'RAMP' and inside(up) then ups[#ups + 1] = up end
            local nk = key3(x + dx, y + dy, z)
            if rtop[nk] and inside(nk - 16777216) then downs[#downs + 1] = nk - 16777216 end
          end
        end
      end
      spend(1)
    end
    return ups, downs
  end
  local function done(R, mouth)
    if #R < CFG.breach_tiles then return {why = string.format('too small (%d tiles)', #R)} end
    local bx, by_, bz = dec3(S.low)
    local mx, my, mz = dec3(mouth)
    local z1 = 0
    for _, k in ipairs(R) do z1 = math.max(z1, k // 16777216) end
    return {tiles = R, n = #R, bottom = {bx, by_, bz}, mouth = {mx, my, mz}, z0 = bz, z1 = z1}
  end
  local cur, cset = level(S.low, CFG.dead_max)
  if not cur then return {why = 'deepest level: ' .. tostring(cset)} end
  local R = {}
  while true do
    local prev = #R
    for _, k in ipairs(cur) do R[#R + 1] = k end
    if #R > CFG.dead_max then return {why = 'too big'} end
    local ups = links(cur)
    if #ups == 0 then return {why = 'no stair up from it'} end
    local nxt, nset = level(ups[1], CFG.dead_level)
    if not nxt then return done(R, ups[1]) end           -- citizens, beds, exposed or big: the mouth
    for _, u in ipairs(ups) do
      if not nset[u] then                                 -- `cur` links up to two places: it is the mouth
        if prev == 0 then return {why = 'deepest level links up twice'} end
        for j = #R, prev + 1, -1 do R[j] = nil end
        return done(R, cur[1])
      end
    end
    local _, nd = links(nxt)
    for _, d in ipairs(nd) do
      if not cset[d] then return done(R, ups[1]) end      -- `nxt` links down elsewhere too: the mouth
    end
    cur, cset = nxt, nset
  end
end

-- FR-62/63: a flood over the citizens' walk groups (their inside tiles and the outside tiles next to them) finds the
-- stairs without counterpart and the interior tiles, instead of a box scan that read mostly hidden rock
local function job_scan(K, paint, why)
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
  local vs, low = {}, nil             -- FR-67: stair and ramp shapes of the main group's inside tiles, the deepest one
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
      if gk[k] == main then
        if sh and (STAIR_KIND[sh] or sh == 'RAMP') then vs[k] = sh end
        if not low or k < low then low = k end            -- keys order by z first
      end
      -- BUG-018: the tiles an opening reaches without a door stay out of the interior burrow
      if inner and gk[k] == main and #inner < CFG.interior_max and not in_any(ex, x, y, z) and not exposed(k) then
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
  -- FR-67: the dead end behind the deepest stair; painted as the refuge burrow when that one is missing
  local dead = {why = main and 'scan limit' or 'no citizen'}
  if main and not res.partial then
    dead = dead_end(K, main, {gk = gk, out = out, vs = vs, rtop = rtop, low = low, cits = cits})
  end
  res.dead = {n = dead.n, bottom = dead.bottom, mouth = dead.mouth, z0 = dead.z0, z1 = dead.z1, why = dead.why}
  mem.scan = res
  local pw = (why == 'lockdown' or why == 'breach') and why or 'interior'
  local q2 = {}
  local _, refuge = burrow_names(K)
  if dead.tiles and not burrow(refuge) then
    local list = {}
    for j, k in ipairs(dead.tiles) do list[j] = {dec3(k)} end
    q2[#q2 + 1] = {name = refuge, list = list, dead = res.dead}
  end
  if inner and #inner > 0 then q2[#q2 + 1] = {name = CFG.interior, list = inner}
  elseif inner then st.painted, dirty = now_t(K), true end   -- nothing to paint (an opening reaches all): retry later
  if #q2 > 0 then
    mem.paint_q = q2
    due('paint', now_t(K), pw)
  end
end

-- FR-33: the whole-interior burrow, FR-67: the dead end as the refuge (burrows screen: add burrow, paint tiles), in
-- chunks
local function job_paint(K, why)
  local queue = mem.paint_q
  mem.paint_q = nil
  if not queue or #queue == 0 then return end
  for _, p in ipairs(queue) do
    local list, n, i = p.list, 0, 1
    while i <= #list do
      local chunk = {}
      for j = i, math.min(#list, i + CFG.paint_chunk - 1) do chunk[#chunk + 1] = list[j] end
      i = i + #chunk
      local ok, r = K.act.burrow_tiles(p.name, chunk, true)
      if not ok then K.log('warn', 'seal: painting %s failed: %s', p.name, tostring(r)); break end
      n = n + (int(r) or 0)
      spend(CFG.work)                                        -- one chunk per frame
    end
    mem.bsize[p.name] = nil
    if p.dead then
      local d = p.dead
      st.dead, dirty = {t = now_t(K), n = n, name = p.name, pos = d.bottom, mouth = d.mouth, z = {d.z0, d.z1}}, true
      K.log('info', 'seal: %s painted with %d tiles: the dead end behind the stair at %d,%d,%d (z%d-%d)', p.name, n,
            d.mouth[1], d.mouth[2], d.mouth[3], d.z0, d.z1)
    else
      st.painted, dirty = now_t(K), true
      K.log('info', 'seal: %s painted with %d of %d interior tiles', p.name, n, #list)
    end
  end
  due('audit', now_t(K), (why == 'lockdown' or why == 'breach') and ('painted ' .. why) or 'painted')
end

---------------------------------------------------------------- the alert burrow (FR-33/37/57, BUG-018/019, FR-67)
-- BUG-018: the separation of burrow `name` from the openings (expose): {exp = true, why, open, routes, d} (an opening
-- reaches it without a closer, d steps from it), {exp = false} (a sealed fort, or the flood never entered it), nil =
-- unknown (no entrance check yet, the burrow is new or changed since, the flood hit its limit). A burrow found exposed
-- stays exposed until it is checked again (painting more tiles never separates it).
local function sep_of(name)
  local s = mem.sepr
  if not s then return nil end
  if s.sealed then return {exp = false} end
  local e = s.by[name]
  if not e then return nil end
  if e.exp then return e end
  local a = mem.audit and mem.audit.burrows and mem.audit.burrows[name]
  if s.partial or (a and a.nb ~= nil and a.nb ~= e.nb) then return nil end
  return e
end

-- BUG-018: a visible hostile (sense's census) stands on a tile of burrow `name` (Run 9: "BREACH: hostile inside Kern+"
-- and the alert kept every citizen in there); per tick and census
local function hostile_in(K, name, t)
  local h = K.census.h
  local c = mem.hin
  if not c or c.t ~= t or c.h ~= h then
    c = {t = t, h = h, by = {}}
    mem.hin = c
  end
  local v = c.by[name]
  if v == nil then
    v = false
    local b = type(h) == 'table' and (int(h.vis) or 0) > 0 and burrow(name)
    if b then
      for _, e in ipairs(type(h.list) == 'table' and h.list or {}) do
        if type(e) == 'table' and int(e.x) and int(e.y) and int(e.z) and in_burrow(b, e.x, e.y, e.z) then
          v = true
          break
        end
      end
    end
    c.by[name] = v
  end
  return v
end

-- BUG-019: the BREACH level and the dead end hold for breach_days after the first such pick of an episode
local function breach_open(K, t)
  local s = int(st.bsince)
  return s == nil or t < s or t - s < rcfg(K).breach_days * DAY
end

-- burrow `name` at level `lvl`: SIEGE (separated, reachable, no hostile in it, the counts and the beds), SOFT (the same
-- with beds short), HOLD (separated and big enough: BUG-011's lockdown fallback, the counts waived), BREACH (separated,
-- reachable, CFG.breach_tiles; no counts, BUG-019) and DEAD (as BREACH, but an opening may reach it CFG.dead_gap steps
-- or more away: the dead end, FR-67). Returns ok, why, danger (refused because an opening reaches it or a hostile
-- stands in it).
local function rate(K, au, name, lvl, t)
  local a = au[name]
  if not (a and a.exists) then return false, 'missing' end
  local s = sep_of(name)
  if s and s.exp and not (lvl == 'DEAD' and (s.d or 0) >= CFG.dead_gap) then return false, s.why, true end
  if hostile_in(K, name, t) then return false, 'hostile inside', true end
  if a.reach == 0 then return false, 'out of the citizens\' reach' end
  if lvl == 'BREACH' or lvl == 'DEAD' then
    if a.tiles < CFG.breach_tiles then return false, string.format('%d tiles<%d', a.tiles, CFG.breach_tiles) end
    return true
  end
  if lvl == 'HOLD' then return a.room == true, a.why end
  if not a.sup then return false, a.why end
  if lvl == 'SIEGE' and a.bed_short then return false, a.why end
  return true
end

-- the civ-alert burrow for `mode`, without side effects. want = default (siege: Kern+, the refuge in BREACH); after a
-- BREACH the refuge is held until CFG.back_days without a visible hostile. In order:
--   1. in BREACH (and while its refuge is held) the refuge at the BREACH level, for breach_days (BUG-019)
--   2. want, Kern+ and the interior burrow at the SIEGE level, then at SOFT (beds short)
--   3. `hold` (BUG-011, a reflex lockdown holds the alert): the interior burrow at HOLD, whatever it lacks: it holds
--      every stock, bed and well inside the fort (but the tiles an opening reaches), so confining to it takes nothing
--      from the citizens but the surface, which is what the lockdown is for
--   4. an opening reaches a candidate or a hostile stands in it (danger), or BREACH: the refuge at BREACH, then at DEAD
--      (FR-67: the dead end behind the deepest stair), for breach_days
--   5. nil = no confinement; flee when there is danger or a BREACH (BUG-018: siege turns the alert off even in a
--      lockdown, the citizens flee on their own)
-- Returns {pick, want, why (the first refusal of an existing burrow), level, forced (the kept interior's own failure),
-- danger, flee}.
local function choose(K, mode, want, hold)
  local kern, refuge = burrow_names(K)
  want = want or (mode == 'BREACH' and refuge or kern)
  if st.swap and want == kern and mode ~= 'PEACE' and quiet(K) < CFG.back_days * DAY then want = refuge end
  local r = {want = want}
  local au = mem.audit and mem.audit.burrows
  if not au then r.pick = want; return r end              -- no audit yet (it runs at boot): as before
  local t = now_t(K)
  local function try(name, lvl)
    local ok, why, danger = rate(K, au, name, lvl, t)
    if ok then r.pick, r.level = name, lvl; return true end
    if danger then r.danger = true end
    if not r.why and au[name] and au[name].exists then r.why = name .. ': ' .. tostring(why) end
    return false
  end
  local bwin = breach_open(K, t)
  local held_refuge = want == refuge and (mode == 'BREACH' or st.swap ~= nil)
  if held_refuge and bwin and try(refuge, 'BREACH') then return r end
  local chain, seen = {}, {}
  for _, n in ipairs({want, kern, CFG.interior}) do
    if not seen[n] then seen[n] = true; chain[#chain + 1] = n end
  end
  for _, lvl in ipairs({'SIEGE', 'SOFT'}) do
    for _, n in ipairs(chain) do if try(n, lvl) then return r end end
  end
  if hold and try(CFG.interior, 'HOLD') then r.forced = au[CFG.interior].why; return r end
  if (r.danger or mode == 'BREACH') and bwin then
    if not held_refuge and try(refuge, 'BREACH') then return r end
    if try(refuge, 'DEAD') then return r end
  end
  r.flee = r.danger == true or mode == 'BREACH'
  return r
end

local HOLD_FRESH = 100     -- ticks a lockdown's alert_burrow(..., hold) stands for publish (siege asks every <= 25)
local function held(K) return mem.hold_t ~= nil and now_t(K) - mem.hold_t <= HOLD_FRESH end

local function publish(K)
  local mode = K.mode()
  local r = choose(K, mode == 'PEACE' and 'ALERT' or mode, nil, held(K))
  local au = mem.audit and mem.audit.burrows or {}
  local a = r.pick and au[r.pick]
  local ok = r.pick ~= nil and r.pick == r.want
  local why = ok and '' or (r.why or '')
  if r.flee then why = 'flee: ' .. why end
  mem.pub = {want = trunc(r.want, 24), burrow = trunc(r.pick or '', 24), tiles = a and a.tiles or 0,
             inside = a and a.inside or 0, ok = ok and 1 or 0, why = trunc(why, 40)}
  local core = mem.core                         -- BUG-028 (d): drink and food days inside Kern+ and the refuge
  if core and core.drink.days then mem.pub.core_d = core.drink.days end
  if core and core.food.days then mem.pub.core_f = core.food.days end
  -- Run 10 (Tiefe+ open to the entrance, beds 8<27, no safe room at pop 110): the refuge burrow for `dfllm plan
  -- check` (no P3+ without it): exists, separated (1, 0 an opening reaches it, -1 not known yet), beds, beds wanted
  local need = mem.audit and mem.audit.need
  if need then
    local _, refuge = burrow_names(K)
    local ra = au[refuge]
    local ex = ra ~= nil and ra.exists == true
    local s = ex and sep_of(refuge) or nil
    mem.pub.ref = {ex = ex and 1 or 0, sep = s == nil and -1 or (s.exp and 0 or 1),
                   beds = ex and math.max(0, int(ra.beds) or 0) or 0, need = math.max(0, int(need.beds) or 0)}
  end
end

-- public (CONTRACTS §7, siege): the burrow the civ alert confines to in `mode`; nil = no confinement. `hold`: a reflex
-- lockdown holds the alert (BUG-011, choose); a missing or too small interior burrow is painted at once then. FR-67: in
-- BREACH, or with an opening reaching the burrows, a missing refuge is painted from the dead end at once (at most
-- daily). The second and third values say why the pick is not `default` (nil when it is), in full ('REFUGE_FAIL
-- <burrow>: <why>[; <interior> kept for the lockdown although <why> | <interior> missing, paint queued | <refuge> is a
-- dead end ... | no separated burrow ...]') and short ('REFUGE_FAIL <burrow>[, lockdown fallback | , <interior>
-- missing | , dead end <refuge> | , citizens flee]'); the fourth is true when the citizens are to flee (BUG-018: no
-- separated burrow; siege turns the alert off even in a lockdown).
function M.alert_burrow(K, mode, default, hold)
  mode = mode or K.mode()
  hold = hold == true
  local kern, refuge = burrow_names(K)
  if default ~= kern then default = (mode == 'BREACH' or default ~= nil) and refuge or kern end
  local t = now_t(K)
  if hold then mem.hold_t = t end
  if mode ~= 'BREACH' and st.swap and (mode == 'PEACE' or quiet(K) >= CFG.back_days * DAY) then
    st.swap, dirty = nil, true
    K.log('info', 'seal: refuge released, confinement back to %s', kern)
  end
  if mode == 'PEACE' and not hold and st.bsince then st.bsince, dirty = nil, true end   -- the episode is over
  local r = choose(K, mode, default, hold)
  local pick, want, why, forced = r.pick, r.want, r.why, r.forced
  if mode == 'BREACH' and pick == refuge and not st.swap then st.swap, dirty = {since = t}, true end
  if (r.level == 'BREACH' or r.level == 'DEAD') and not st.bsince then
    st.bsince, dirty = t, true
    K.log('info', 'seal: %s holds the citizens without drink, food or bed counts (%s level) for %d days', pick,
          r.level, rcfg(K).breach_days)
  end
  local au = mem.audit and mem.audit.burrows
  local ia = au and au[CFG.interior]
  local ra = au and au[refuge]
  -- FR-67: the refuge is missing while an opening reaches the burrows (or in a breach): the dead end now (at most once
  -- a day; scan, paint and the audit after it run as urgent jobs)
  local dtail = ''
  if au and not (ra and ra.exists) and (r.danger or mode == 'BREACH') and (mode ~= 'PEACE' or hold) then
    if not (mem.dead_ask and t - mem.dead_ask < DAY and t >= mem.dead_ask) then
      mem.dead_ask = t
      due('scan', t, 'breach')
    end
    local dd = mem.scan and mem.scan.dead
    dtail = '; ' .. refuge .. ((dd and dd.why) and (' missing, no dead end: ' .. dd.why) or ' missing, dead end queued')
  end
  -- BUG-011: a lockdown without a usable interior burrow paints one now (at most once a day; scan, paint and the
  -- audit after it run as urgent jobs), so the next ask confines instead of leaving the whole fort open
  local tail
  if forced then tail = string.format('; %s kept for the lockdown although %s', CFG.interior, forced)
  elseif r.level == 'BREACH' or r.level == 'DEAD' then
    if pick ~= want then
      tail = string.format('; %s is %s: no drink, food or bed counts for %d days', pick,
                           r.level == 'DEAD' and 'the dead end' or 'separated', rcfg(K).breach_days)
    end
  elseif not pick then
    -- (an interior burrow an opening reaches is never repainted: painting adds tiles, it never separates one)
    local ipaint = hold and au and not (ia and ia.room) and not (sep_of(CFG.interior) or {}).exp
    if ipaint and not (mem.lock_paint and t - mem.lock_paint < DAY and t >= mem.lock_paint) then
      mem.lock_paint = t
      due('scan', t, 'lockdown', true)
    end
    local itail = ipaint and ('; ' .. CFG.interior .. ((ia and ia.exists) and (': ' .. ia.why) or ' missing')
                              .. ', paint queued') or ''
    if r.flee then tail = '; no separated burrow: civ alert off, citizens flee on their own' .. itail .. dtail
    elseif ipaint then tail = itail end
  end
  if pick ~= want and why then
    -- BUG-008: once per episode, again only when the refused burrow, the fallback or the reason changed, and then
    -- not before max(1 game day, 60 s wall clock) (util/cadence; the unconditional daily repeat was 3 s at timestream)
    local ids = {want .. '>' .. tostring(pick)}
    local toks, now = {trunc(why, 60), forced and 'forced' or (r.flee and 'flee' or (r.level or ''))}, K.now()
    -- (no separated burrow is news that goes out at once: the alert is switched off)
    local o = r.flee and {ticks = 0, wall_s = 0} or {ticks = DAY, wall_s = 60}
    if CAD.due(st.refuge_rec, now, ids, toks, o) then
      st.refuge_rec, dirty = CAD.mark(now, ids, toks), true
      local a = pick and (au or {})[pick]
      local ws = sep_of(want)
      K.emit('REFUGE_FAIL', 'A', trunc(string.format('alert burrow %s refused (%s): %s%s', want, why,
             pick and ('confining to ' .. pick) or (r.flee and 'no confinement' or 'no confinement, the whole fort'),
             tail or ''), 200),
             {burrow = want, fallback = pick or '', why = trunc(why .. (tail or ''), 120), tiles = a and a.tiles or 0,
              inside = a and a.inside or 0, mode = mode, level = r.level, flee = r.flee and 1 or 0,
              open = ws and ws.exp and ws.open or nil})
    end
  end
  if pick == want and st.refuge_rec then st.refuge_rec, dirty = nil, true end   -- the episode ended
  publish(K)
  save(K)
  local note, brief
  if pick ~= want then
    note = trunc((why and ('REFUGE_FAIL ' .. why) or (want .. ' missing')) .. (tail or ''), 160)
    brief = (why and ('REFUGE_FAIL ' .. want) or (want .. ' missing')) .. (forced and ', lockdown fallback' or '')
    if r.flee then brief = brief .. ', citizens flee'
    elseif r.level == 'BREACH' or r.level == 'DEAD' then
      brief = brief .. (r.level == 'DEAD' and ', dead end ' or ', ') .. tostring(pick)
    elseif tail and not forced then
      brief = brief .. ', ' .. CFG.interior .. ((ia and ia.exists) and ' too small' or ' missing')
    end
  end
  return pick, note, brief, r.flee == true
end

-- public (BUG-013, gate): the lever burrow CFG.levers ('Hebel+'; burrows screen: add burrow, paint) holds `tiles`
-- ({{x,y,z}}: every linked lever of the bridges gate holds). gate hands it to siege's alert list while a pull is
-- pending on a lever outside the alert burrow: a confined civilian takes only jobs inside his burrows, but walks
-- outside them to get there. A missing tile (a new lever, the burrow deleted or erased by the player) is painted at
-- once; the tiles are trusted for CFG.lever_check ticks, a refused paint is tried again after CFG.lever_retry. Tiles
-- are never removed (the paint act only adds; a stale lever tile is listed only while a pull is pending). Returns the
-- name, or nil and why.
function M.lever_burrow(K, tiles)
  local list, parts = {}, {}
  for _, p in ipairs(type(tiles) == 'table' and tiles or {}) do
    if #list >= CFG.levers_max then break end
    local x, y, z
    if type(p) == 'table' then x, y, z = int(p[1]), int(p[2]), int(p[3]) end
    if x and y and z then
      list[#list + 1] = {x, y, z}
      parts[#parts + 1] = kstr(x, y, z)
    end
  end
  if #list == 0 then return nil, 'no lever' end
  local sig, t = table.concat(parts, ';'), now_t(K)
  local c, b = mem.lev, burrow(CFG.levers)
  if c and c.sig == sig and t >= c.t then
    if c.fail and t - c.t < CFG.lever_retry then return nil, c.fail end
    if b and not c.fail and t - c.t < CFG.lever_check then return CFG.levers end
  end
  local miss = {}
  for _, p in ipairs(list) do
    if not (b and in_burrow(b, p[1], p[2], p[3])) then miss[#miss + 1] = p end
  end
  if #miss > 0 then
    local ok, r = K.act.burrow_tiles(CFG.levers, miss, true)
    if not ok then
      mem.lev = {sig = sig, t = t, fail = tostring(r)}
      K.log('warn', 'seal: painting %s failed: %s', CFG.levers, tostring(r))
      return nil, tostring(r)
    end
    mem.bsize[CFG.levers] = nil
    K.log('info', 'seal: %s painted with %d lever tiles (%d linked levers)', CFG.levers, int(r) or #miss, #list)
  end
  mem.lev = {sig = sig, t = t}
  return CFG.levers
end

-- public (BUG-012, reflex): the doors of the last entrance check: {tick (of its BFS), sealed 0|1, routes,
-- doors = {{id, pos}}, open = {{pos, kind}} (openings with neither a door nor a bridge on them or their route)}; nil
-- before the first check. `refresh`: the reflex starts a lockdown, so an urgent check with a fresh BFS is queued (the
-- PEACE answer may be up to CFG.bfs_every old) and the caller polls again for its doors
function M.entrance_doors(K, refresh)
  if refresh then due('seal', now_t(K), 'lockdown') end
  local s = mem.seal
  if not s then return nil end
  local c = mem.door_x
  if c and c.src == s then return c.x end
  local x = {tick = s.bfs or s.tick, sealed = s.sealed and 1 or 0, routes = s.routes or 0, doors = {}, open = {}}
  for _, d in ipairs(s.doors or {}) do x.doors[#x.doors + 1] = {id = d[1], pos = {d[2], d[3], d[4]}} end
  for _, o in ipairs(s.openings or {}) do
    if #(o.doors or {}) == 0 and o.gate ~= 1 then
      x.open[#x.open + 1] = {pos = {o.pos[1], o.pos[2], o.pos[3]}, kind = tostring(o.bld)}
    end
  end
  mem.door_x = {src = s, x = x}
  return x
end

-- public (reflex, the lockdown's doors): the citizens (soldiers excluded, as for the gates) on the outside side of
-- each door in `ids`: on a revealed open-sky tile of the door's walk group, on the porch of an opening the door closes
-- (the last entrance check), or in the doorway. A door is forbidden only once nobody is left there, so nobody is
-- locked out with the army. Returns {[id] = n} and the number of distinct citizens counted; citizens by census id.
function M.door_outside(K, ids)
  local s = mem.seal
  local cu = K.census.u
  local sold = {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.soldier_ids) == 'table' and cu.soldier_ids or {}) do
    sold[id] = true
  end
  local cits = {}
  for _, c in ipairs(citizens(K)) do
    if not sold[c.id] then
      local des = rev(c.x, c.y, c.z)
      local k = key3(c.x, c.y, c.z)
      cits[#cits + 1] = {id = c.id, g = c.g, k = k, out = des and des.outside == true,
                         porch = s and s.porch and s.porch[k]}
    end
  end
  local per, who, n = {}, {}, 0
  for _, id in ipairs(type(ids) == 'table' and ids or {}) do
    local c = 0
    local b = int(id) and df.building.find(id)
    if b then
      local x, y, z = b.centerx or b.x1, b.centery or b.y1, b.z
      local dk, dg = key3(x, y, z), grp(x, y, z)
      local ops = s and s.door_ops and s.door_ops[id]
      for _, cz in ipairs(cits) do
        local hit = cz.k == dk or (cz.out and dg ~= nil and dg ~= 0 and cz.g == dg)
        if not hit and ops and cz.porch then
          for oi in pairs(cz.porch) do if ops[oi] then hit = true; break end end
        end
        if hit then
          c = c + 1
          if not who[cz.id] then who[cz.id], n = true, n + 1 end
        end
      end
    end
    per[id] = c
  end
  return per, n
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

---------------------------------------------------------------- BUG-028: walk groups for siege's supply rules
-- Run 10 y419 (48 goblins before O1): BREACH held all three bridges up for 23 days, 13 citizens between O1 and B1/B2
-- had no drink (thirst up to 74090), at least 2 died dehydrated. siege asks seal (the walk-group reader) three things:
-- the groups now (M.groups), the groups around a bridge (M.sides) and, before a raise, what the raise would cut apart
-- (M.split). Revealed tiles only.

-- public (BUG-028, siege): the walk groups now, read in one go (one frame, one numbering, BUG-021): the citizens on
-- each group ({id, x, y, z}), the groups holding drink and food (one tile per group of the last audit's stock and its
-- re-check tiles, read again), the groups visible hostiles stand on, and `stale` while the audit is older than the last
-- change of a bridge, door or construction (then an urgent audit is queued; its per-group stock tiles come from the
-- new numbering). nil before the first audit. Cached per tick.
function M.groups(K)
  local t = now_t(K)
  local c = mem.grp_now
  if c and c.t == t then return c.r end
  local R = mem.reach
  if not R then return nil end
  local left = mem.left
  mem.left = math.huge                      -- a synchronous read (siege asks): never yields
  local cit = {}
  for _, u in ipairs(citizens(K)) do
    local e = cit[u.g]
    if not e then e = {}; cit[u.g] = e end
    e[#e + 1] = {u.id, u.x, u.y, u.z}
  end
  local has = {}
  for _, cls in ipairs({'drink', 'food'}) do
    local s = {}
    for _, p in pairs(R.cls[cls].at) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then s[g] = true end
    end
    for _, p in ipairs(R.reps[cls] or {}) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then s[g] = true end
    end
    has[cls] = s
  end
  local hos = {}
  local h = K.census.h
  for _, e in ipairs(type(h) == 'table' and type(h.list) == 'table' and h.list or {}) do
    if type(e) == 'table' and int(e.x) and int(e.y) and int(e.z) then
      local g = grp(e.x, e.y, e.z)
      if g and g ~= 0 then hos[g] = (hos[g] or 0) + 1 end
    end
  end
  mem.left = left
  local stale = (mem.fp_t or -1) > R.tick
  if stale then due('audit', t, 'quick:groups') end
  -- sealed: seal's last entrance check found no route from the map edge to a citizen and came after the last change
  local sealed = mem.seal ~= nil and mem.seal.sealed == true and (mem.seal.tick or -1) >= (mem.fp_t or -1)
  local r = {tick = t, audit = R.tick, stale = stale, sealed = sealed, cit = cit, drink = has.drink, food = has.food,
             hostile = hos}
  mem.grp_now = {t = t, r = r}
  return r
end

-- the revealed walkable tiles around a footprint on its level (its ring), as keys
local function ring_keys(fp)
  local r = {}
  for x = fp[1] - 1, fp[4] + 1 do
    for y = fp[2] - 1, fp[5] + 1 do
      if x < fp[1] or x > fp[4] or y < fp[2] or y > fp[5] then r[#r + 1] = key3(x, y, fp[3]) end
    end
  end
  return r
end

-- public (BUG-028, siege): the walk groups of the revealed walkable tiles around a bridge footprint: one when nothing
-- separates its sides (a lowered bridge), two or more while it is raised
function M.sides(K, fp)
  local s = {}
  if type(fp) ~= 'table' or not int(fp[1]) then return s end
  for _, k in ipairs(ring_keys(fp)) do
    local g = grp(dec3(k))
    if g and g ~= 0 then s[g] = true end
  end
  return s
end

-- BUG-028 (c): what raising the bridges of one request would cut apart, before they rise. The footprints are blocked
-- and a flood starts from each side of each footprint (its ring tiles, joined where they touch), one flood per side,
-- round-robin, over revealed walkable tiles of the side's walk group; floods that meet are one part. The outward side
-- of an outer bridge (the one with more open-sky ring tiles) is the outside and is never flooded: a part that reaches
-- it is the outside too and stops. A part whose floods ran out is small (between two gates); the flood ends once at
-- most one part still grows and is clearly the biggest (the rest of the fort), or after CFG.split_max tiles (unknown).
-- The stock per part comes from the item census tiles. The cost is the small parts, never the whole fort.
local function split_pass(K, req)
  local t0 = now_t(K)
  local blocked = {}
  for _, b in ipairs(req.list) do
    local fp = b.fp
    for x = fp[1], fp[4] do for y = fp[2], fp[5] do blocked[key3(x, y, fp[3])] = true end end
  end
  -- the sides: the walkable ring tiles of each footprint, joined where they touch (Chebyshev 1, same group)
  local sides = {}
  for _, b in ipairs(req.list) do
    local tiles = {}
    for _, k in ipairs(ring_keys(b.fp)) do
      if not blocked[k] then
        local x, y, z = dec3(k)
        local des = rev(x, y, z)
        local g = des and grp(x, y, z)
        if g and g ~= 0 then tiles[#tiles + 1] = {k = k, x = x, y = y, g = g, out = des.outside == true} end
      end
      spend(3)
    end
    local up = {}
    for i = 1, #tiles do up[i] = i end
    local function f(i) while up[i] ~= i do up[i] = up[up[i]]; i = up[i] end; return i end
    for i = 1, #tiles do
      for j = i + 1, #tiles do
        local a, o = tiles[i], tiles[j]
        if a.g == o.g and math.abs(o.x - a.x) <= 1 and math.abs(o.y - a.y) <= 1 then up[f(j)] = f(i) end
      end
    end
    local by = {}
    for i, a in ipairs(tiles) do
      local r = f(i)
      local s = by[r]
      if not s then
        s = {tiles = {}, nout = 0, g = a.g, bridge = b.name}
        by[r], sides[#sides + 1] = s, s
      end
      s.tiles[#s.tiles + 1] = a.k
      if a.out then s.nout = s.nout + 1 end
    end
    -- the outward side of an outer bridge: the one with the most open-sky ring tiles (never flooded: the outside)
    if b.role == 'outer' then
      local best
      for _, s in pairs(by) do if s.nout > 0 and (not best or s.nout > best.nout) then best = s end end
      if best then best.outward = true end
    end
  end
  -- one flood per side; label 0 = the outside (stays a root)
  local par, lab, gof, queue, active = {[0] = 0}, {}, {}, {}, {}
  local function find(i) while par[i] ~= i do par[i] = par[par[i]]; i = par[i] end; return i end
  local function union(a, b)
    local ra, rb = find(a), find(b)
    if ra == rb then return end
    if rb == 0 then ra, rb = rb, ra end
    par[rb] = ra
  end
  for _, s in ipairs(sides) do
    local id = 0
    if not s.outward then
      id = #active + 1
      par[id], queue[id], active[id] = id, {h = 1}, id
    end
    s.id = id
    for _, k in ipairs(s.tiles) do
      if lab[k] == nil then
        lab[k], gof[k] = id, s.g
        if id ~= 0 then queue[id][#queue[id] + 1] = k end
      elseif lab[k] ~= id then union(lab[k], id) end
    end
  end
  local nb, rtop, n, partial = {}, {}, 0, false
  while true do
    local live, nlive, size, done_max = {}, 0, {}, 0
    for id = 1, #active do
      local q = queue[id]
      if find(id) == 0 then q.h = #q + 1 end              -- joined the outside: nothing more to learn there
      local r = find(id)
      size[r] = (size[r] or 0) + #q
      if q.h <= #q and not live[r] then live[r], nlive = true, nlive + 1 end
    end
    for r, n0 in pairs(size) do if not live[r] and r ~= 0 then done_max = math.max(done_max, n0) end end
    -- the last part still growing is the rest of the fort once it is clearly the biggest (or it ran out too)
    local big = true
    for r in pairs(live) do if size[r] < math.max(64, 2 * done_max) then big = false end end
    if nlive == 0 or (nlive == 1 and big) then break end
    if n >= CFG.split_max then partial = true; break end
    for id = 1, #active do
      local q, c = queue[id], 0
      while q.h <= #q and c < 32 do
        local k = q[q.h]
        q.h, c, n = q.h + 1, c + 1, n + 1
        local g = gof[k]
        local x, y, z = dec3(k)
        local m = steps(x, y, z, nb)
        for i = 1, m do
          local nk = nb[i]
          local l = lab[nk]
          if l == nil and not blocked[nk] then
            local gg = grp(dec3(nk))
            if (gg == nil or gg == 0) and i <= 8 then         -- down a ramp: the open top of a ramp one level down
              if rtop[nk] == nil then rtop[nk] = ramp_top(nk) end
              if rtop[nk] then
                nk = nk - 16777216
                l = lab[nk]
                gg = l == nil and grp(dec3(nk)) or nil
              end
            end
            if l == nil and gg == g and not blocked[nk] then lab[nk], gof[nk] = id, g; q[#q + 1] = nk end
          end
          if l ~= nil and l ~= id then union(l, id) end
        end
        spend(12)
      end
    end
  end
  -- the parts, one per root (parts[1] = the outside); a part still growing is the rest of the fort
  local parts, pid_of = {}, {}
  local function part(root)
    local p = pid_of[root]
    if not p then
      p = {id = #parts + 1, outside = root == 0, small = false, drink = 0, food = 0, bridges = {}}
      parts[#parts + 1], pid_of[root] = p, p
    end
    return p
  end
  part(0)
  local rest
  for id = 1, #active do
    local p = part(find(id))
    if not p.outside then
      local q = queue[id]
      if q.h <= #q then p.rest = true end
    end
  end
  for _, p in ipairs(parts) do
    if not p.outside then
      if p.rest then rest = p else p.small = true end
    end
  end
  local edges = {}
  for _, s in ipairs(sides) do
    local p = part(find(s.id))
    p.bridges[s.bridge] = true
    local e = edges[s.bridge] or {}
    e[p.id], edges[s.bridge] = true, e
  end
  local tiles = {}
  for k, l in pairs(lab) do tiles[k] = part(find(l)).id end
  -- the stock per part: census tiles on a side's group (a flooded tile's part, else open sky = the outside, else the
  -- rest of the fort)
  local G = {}
  for _, s in ipairs(sides) do G[s.g] = true end
  local I = mem.items
  for _, k in ipairs(I and I.keys or {}) do
    local c = I.at[k]
    local x, y, z = dec3(k)
    local des = rev(x, y, z)
    local g = des and grp(x, y, z)
    if g and G[g] then
      local pid = tiles[k]
      local p = pid and parts[pid] or (des.outside and parts[1]) or rest
      if p then p.drink, p.food = p.drink + c[1], p.food + c[2] end
    end
    spend(3)
  end
  return {t = t0, sig = req.sig, partial = partial, n = n, parts = parts, tiles = tiles, rest = rest and rest.id,
          edges = edges, G = G, fp = mem.fp}
end

local function job_split(K)
  for _, sig in ipairs(sorted_keys(mem.split_q or {})) do
    local req = mem.split_q[sig]
    mem.split[sig] = split_pass(K, req)
    mem.split_q[sig] = nil
    mem.stats.split = (mem.stats.split or 0) + 1
  end
end

-- public (BUG-028 c, siege): what raising `list` ({{name, fp, role}}, the bridges about to be raised together) would
-- cut apart, for the citizens where they stand now (soldiers excluded): nil and 'pending' (an urgent split is queued;
-- ask again) or 'unknown' (no item census yet, the flood hit its limit), else {parts = {{id, n, ids, drink, food,
-- small, outside, rest, bridges = {name = true}}}, edges = {name = {part id = true}}, cut = {part ids with citizens
-- and no drink or no food}}. A result is used while no bridge, door or construction changed (the watcher's
-- fingerprint) and for at most CFG.split_age ticks.
function M.split(K, list)
  local names = {}
  for _, b in ipairs(type(list) == 'table' and list or {}) do
    if type(b) == 'table' and type(b.name) == 'string' and type(b.fp) == 'table' and #b.fp == 6 then
      names[#names + 1] = b.name
    end
  end
  if #names == 0 then return nil, 'no bridge' end
  table.sort(names)
  local sig = table.concat(names, '+')
  local t = now_t(K)
  local r = mem.split[sig]
  if not r or r.fp ~= mem.fp or t - r.t > CFG.split_age or t < r.t then
    if not mem.items then return nil, 'unknown' end
    mem.split_q[sig] = mem.split_q[sig] or {sig = sig, list = list}
    due('split', t, 'split')
    return nil, 'pending'
  end
  if r.partial then return nil, 'unknown' end
  local sold = {}
  local cu = K.census.u
  for _, id in ipairs(type(cu) == 'table' and type(cu.soldier_ids) == 'table' and cu.soldier_ids or {}) do
    sold[id] = true
  end
  local parts = {}
  for i, p in ipairs(r.parts) do
    parts[i] = {id = p.id, n = 0, ids = {}, drink = p.drink, food = p.food, small = p.small, outside = p.outside,
                rest = p.rest, bridges = p.bridges}
  end
  for _, c in ipairs(citizens(K)) do
    if not sold[c.id] and r.G[c.g] then
      local k = key3(c.x, c.y, c.z)
      local pid = r.tiles[k]
      local des = not pid and rev(c.x, c.y, c.z)
      local p = pid and parts[pid] or (des and des.outside and parts[1]) or (r.rest and parts[r.rest])
      if p then p.n = p.n + 1; p.ids[#p.ids + 1] = c.id end
    end
  end
  local cut = {}
  for _, p in ipairs(parts) do
    if p.n > 0 and (p.drink == 0 or p.food == 0) then cut[#cut + 1] = p.id end
  end
  return {parts = parts, edges = r.edges, cut = cut, t = r.t}
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
    if not first then mem.fp_t = t end          -- BUG-028: a bridge moved: group reads older than this are stale
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
  scan = function(K, d) job_scan(K, d.arg == true, d.why) end,
  paint = function(K, d) job_paint(K, d.why) end,
  split = function(K) job_split(K) end,
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
  if peace and not st.pep and t - (mem.retire_t or -CFG.seal_every) >= CFG.seal_every then
    mem.retire_t = t
    due('perim', t, 'retire')
  end
end

-- urgent jobs run at CFG.rate_urgent and before every background job: a lever pull, a siege, a construction outside
-- PEACE, perimeter.record, a CUTOFF re-check, a mode change, the first result after a load
local URGENT_SEAL = {lever = true, siege = true, record = true, inspect = true, lockdown = true}
local function urgent(K, name, d)
  if name == 'quick' then return true end
  if name == 'split' then return K.mode() ~= 'PEACE' or held(K) end     -- BUG-028: siege waits for it to raise
  if (name == 'edges' and not mem.edges) or (name == 'audit' and not mem.reach) or (name == 'scan' and not mem.scan)
     or (name == 'seal' and not mem.seal) then return true end
  local why = d and d.why or ''
  -- BUG-011: a lockdown without its interior burrow (FR-67: a breach without its refuge): the scan, the paint and the
  -- audit after it
  if (name == 'scan' or name == 'paint' or name == 'audit')
     and (why:find('lockdown', 1, true) or why:find('breach', 1, true)) then return true end
  -- BUG-018: a burrow changed since the exposure flood, outside PEACE or in a lockdown
  if name == 'seal' then
    return URGENT_SEAL[why] == true or (why == 'construction' and K.mode() ~= 'PEACE')
           or (why == 'refuge' and (K.mode() ~= 'PEACE' or held(K)))
  end
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
  mem.fr = (mem.fr or 0) + 1                      -- a frame count: DF pointers are fetched again after it changed
  local name, d, u = pick(K, t)
  if not name then return nil end
  if not u and type(K.busy) == 'function' and K.busy() then return nil end   -- BUG-026: background work waits
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
        flag_sig = type(p.flag_sig) == 'string' and p.flag_sig or nil, pep = int(p.pep), bsince = int(p.bsince),
        sup_rec = type(p.sup_rec) == 'table' and p.sup_rec or nil}
  if type(p.dead) == 'table' and int(p.dead.t) then
    local d = p.dead
    st.dead = {t = int(d.t), n = int(d.n) or 0, name = type(d.name) == 'string' and d.name or nil,
               pos = type(d.pos) == 'table' and d.pos or nil, mouth = type(d.mouth) == 'table' and d.mouth or nil,
               z = type(d.z) == 'table' and d.z or nil}
  end
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
         stats = {}, split = {}, split_q = {}}
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

-- perimeter episodes (FR-56/60): one opens when the fort leaves quiet (ALERT, SIEGE, BREACH, RECOVERY, or a reflex
-- lockdown in any mode) with the 'pre' pass (pieces already gone are retired, never rebuilt) and closes when it is
-- quiet again (PEACE without a lockdown) with the after-siege 'post' diff: lost pieces re-queued, PERIMETER_BROKEN.
-- Before, only SIEGE/BREACH opened one and only RECOVERY/SIEGE_END diffed, so a small ambush (ALERT, or a lockdown
-- that never became a siege) left a destroyed wall unnoticed, and a PEACE retire pass dropped it for good.
-- Level-triggered (step and every mode change), so a missed event or a reload cannot leave one open.
local EPISODE = {ALERT = true, SIEGE = true, BREACH = true, RECOVERY = true}
local function episode(K, t)
  local busy = EPISODE[K.mode()] == true
  if not busy then
    local ok, why = K.call('reflex', 'holding')
    busy = ok and type(why) == 'string' and why ~= ''
  end
  if busy and not st.pep then
    st.pep, dirty = t, true
    due('perim', t, 'pre')
  elseif not busy and st.pep then
    st.pep, dirty = nil, true
    due('perim', t + CFG.lever_delay, 'post')
    due('seal', t + CFG.lever_delay, 'siege')
    K.log('info', 'seal: quiet again: perimeter diff after the episode')
  end
end

function M.step(K, budget, ctx)
  local t = now_t(K)
  if not (ctx and ctx.cont) then
    watch(K, t)
    schedule_periodic(K, t)
    episode(K, t)
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
  episode(K, t)                                         -- 'pre' when an episode opens, 'post' when it closes
  if to == 'RECOVERY' then
    due('perim', t + CFG.lever_delay, 'post')
    due('seal', t + CFG.lever_delay, 'siege')
  end
  if to == 'PEACE' and st.swap then st.swap, dirty = nil, true end
  -- BUG-028 (b): siege leaves BREACH for SIEGE only once the fort is sealed again: the citizens may leave the refuge
  if from == 'BREACH' and to == 'SIEGE' and st.swap then
    st.swap, dirty = nil, true
    K.log('info', 'seal: breach over (sealed): refuge released')
  end
  if to == 'PEACE' and st.bsince and not held(K) then st.bsince, dirty = nil, true end   -- BUG-019: a new episode
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
  if args.key == 'refresh' and mem.run.seal then             -- a refresh answers now: a running check is dropped
    mem.run.seal = nil
    mem.stats.dropped = (mem.stats.dropped or 0) + 1
  end
  if not mem.seal or args.key == 'refresh' then
    if not mem.run.seal then sync(job_seal, K, 'inspect') end
  end
  local s = mem.seal
  if not s then return true, 'entrances: the first check is running', {} end
  local msg = s.msg or '?'
  if not s.sealed then                                 -- BUG-012: what a lockdown can lock
    local x = M.entrance_doors(K)
    msg = string.format('%s; %d entrance door%s, %d opening%s without one', msg, #x.doors, #x.doors == 1 and '' or 's',
                        #x.open, #x.open == 1 and '' or 's')
  end
  return true, msg, {tick = s.tick, why = s.why, sealed = s.sealed, routes = s.routes, first = s.first,
                     openings = s.openings, edge = s.edge, len = s.len, via = s.via, partial = s.partial,
                     expect_sealed = s.expect, bfs = s.bfs, reused = s.reused and 1 or 0, closed = s.closed,
                     doors = s.doors}
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
  local t = now_t(K)
  local b = {}
  for name, a in pairs(au.burrows) do
    -- ok = the SIEGE level (BUG-018: separation included), counts = the counts alone, breach = the BREACH level,
    -- sep 1 separated / 0 an opening reaches it (open: those entrances, exp: its exposed tiles, steps) / -1 unknown
    local s = sep_of(name)
    local why = a.why
    if s and s.exp then why = s.why .. (why ~= '' and (', ' .. why) or '') end
    b[name] = {exists = a.exists and 1 or 0, tiles = a.tiles, inside = a.inside, drink = a.drink, food = a.food,
               beds = a.beds, wells = a.wells, ok = rate(K, au.burrows, name, 'SIEGE', t) and 1 or 0,
               counts = a.ok and 1 or 0, breach = rate(K, au.burrows, name, 'BREACH', t) and 1 or 0,
               sep = s == nil and -1 or (s.exp and 0 or 1), open = s and s.exp and s.open or nil,
               exp = s and s.exp and s.n or nil, steps = s and s.exp and s.d or nil, reach = a.reach, why = why}
  end
  local choice = {}
  local function ch(m, hold)
    local r = choose(K, m, nil, hold)
    return {want = r.want, burrow = r.pick or '', level = r.level, flee = r.flee and 1 or nil}
  end
  for _, m in ipairs({'ALERT', 'SIEGE', 'BREACH', 'RECOVERY'}) do choice[m] = ch(m) end
  choice.LOCKDOWN = ch(K.mode() == 'BREACH' and 'BREACH' or 'ALERT', true)   -- BUG-011: a reflex lockdown
  publish(K)
  local p = mem.pub
  local rc, sp = rcfg(K), mem.sepr
  local need = au.need and {tiles = au.need.tiles, drink = au.need.drink, food = au.need.food, beds = au.need.beds,
                            beds_rule = string.format('ceil(%d citizens x %d%%)', au.need.cit, au.need.bed_pct),
                            breach_tiles = CFG.breach_tiles, breach_days = rc.breach_days} or nil
  local dead = mem.scan and mem.scan.dead
  -- a plan hint: what the refuge lacks for the SIEGE level (it holds without counts only in a breach, breach_days)
  local _, refuge = burrow_names(K)
  local ra = au.burrows[refuge]
  local hint
  if ra and ra.exists and not ra.ok then
    hint = trunc(string.format('%s holds without counts only in a breach (%d days): for a siege it needs %s; plan a '
                               .. 'stockpile and bedrooms there', refuge, rc.breach_days, ra.why), 200)
  end
  return true, string.format('alert %s: %s, %d tiles, %d/%d inside%s', K.mode(),
                             p.burrow ~= '' and p.burrow or 'no confinement',
         p.tiles, p.inside, au.cit, p.why ~= '' and (' (' .. p.why .. ')') or ''),
         {tick = au.tick, cit = au.cit, burrows = b, choice = choice, swap = st.swap,
          quiet = quiet(K) == math.huge and -1 or quiet(K), need = need, bsince = st.bsince, hint = hint,
          supply = mem.core,                    -- BUG-028 (d): drink and food inside Kern+/the refuge vs the stock
          sep = sp and {tick = sp.tick, sealed = sp.sealed and 1 or 0, partial = sp.partial and 1 or 0, n = sp.n}
                or nil,
          dead = (dead or st.dead) and {n = dead and dead.n, bottom = dead and dead.bottom, mouth = dead and dead.mouth,
                                        z = dead and dead.z0 and {dead.z0, dead.z1} or nil, why = dead and dead.why,
                                        painted = st.dead} or nil}
end

return M
