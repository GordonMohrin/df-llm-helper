-- seal (FR-22/24/33/37/54/56/57): reachability, the seal against the map edge, the perimeter and the civ-alert
-- refuge, from walk groups and revealed tiles only. Fair play (CONTRACTS §1.4): a tile is read only after
-- `designation.hidden` was checked; walk groups (dfhack.maps.getWalkableGroup, DF's own job-feasibility cache)
-- are read for revealed tiles only; units only by census id. Group ids change over time, so every check
-- compares against the groups the citizens stand on now, never a stored id.
--   reach     (FR-22) walkable groups of citizens, food, drink, seeds, beds, farm plots, wells, depot and the map
--             edge; every class off the main citizen group is flagged, so is every STAIR_UP/STAIR_DOWN without its
--             counterpart. CUTOFF (A) when citizens lose the group of their food, drink or beds, with the tile that
--             did it. Runs periodically, before a closing construction is queued (runner.apply -> seal.closing) and
--             after every change of constructions, doors, hatches and bridges (a cheap re-check of the known
--             positions first, the full audit only when it looks worse)
--   seal      (FR-54) walk groups of the map-edge tiles against the citizens' groups ("seal verified: no route");
--             otherwise a sliced BFS from the citizens over revealed walkable tiles to the first map-edge tile: the
--             first leak (tile, building, door/bridge state) and the openings of the interior (independent
--             routes). After every siege and lever pull; SEAL_LEAK (A) when the gates are up and a route remains
--   perimeter (FR-56) walls, doors, gates and killbox tiles of defense projects, of the manifest and of the
--             inside/outside boundary (learned by the BFS in PEACE), persisted in m.seal; after a siege they are
--             compared with the map, lost pieces re-queued (runner.repair) and PERIMETER_BROKEN (A) raised
--   defense   (FR-24) every bridge's real gate_flags, the walk groups on its sides and its levers' links
--   refuge    (FR-33/37/57) burrow audits (tiles, citizens inside, drink, food, beds) and alert_burrow(mode): the
--             civ-alert burrow siege uses. Kern+ normally, the refuge (Tiefe+) in BREACH and until CFG.back_days
--             quiet days, never a burrow without drink, food and beds for the population: the fallback is the
--             interior burrow (CFG.interior, painted from revealed walkable inside tiles of the citizens' group),
--             else no confinement at all; REFUGE_FAIL (A) says so
-- Work runs in coroutines, CFG.work units per frame; the BFS is bounded (CFG.bfs_max).
local M = {name = 'seal', every = {ticks = 50}, verbs = {}, on = {}, inspect = {}}

local DAY = 1200
M.CFG = {
  work = 800,                 -- work units per frame (a tile, item or building read costs 1-4)
  audit_every = 3 * DAY,      -- full reach + refuge audit in PEACE ...
  audit_alert = DAY,          -- ... and in the other modes
  quick_every = 100,          -- fingerprint poll (constructions, doors, hatches, bridges)
  quick_min = 300,            -- ticks between two re-checks it triggers
  seal_every = 7 * DAY,       -- periodic entrance check
  edges_every = 7 * DAY,      -- map-edge tile list
  scan_every = 3 * DAY,       -- stairs and interior tiles
  lever_delay = 40,           -- ticks after a bridge moved before the entrance check (walk groups settle)
  bfs_max = 60000,            -- tiles the entrance BFS may visit
  blame_max = 4000,           -- tiles the CUTOFF blame search may visit
  edges_max = 8000, reps_max = 300, entries_max = 400, routes_max = 8, pend_max = 2000,
  scan_margin = {12, 12, 3}, scan_max = 250000,
  pred_near = 25,             -- FR-33: a wild large predator counts only this close to an entrance (sense)
  back_days = 3,              -- FR-57: the refuge stays the confinement until this many days without a hostile
  min_tiles = 20, drink_per_cit = 1, food_per_cit = 1, bed_pct = 25,   -- FR-37 burrow audit (per citizen)
  interior = 'Innen+',        -- the whole-interior burrow, painted when Kern+ fails its audit
  paint_chunk = 400, interior_max = 20000, repaint = 7 * DAY,
  perim_max = 1500, requeue_cool = 7 * DAY, fail_every = DAY,
}
local CFG = M.CFG

local ITEM_CATS = {'DRINK', 'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH', 'SEEDS'}
local ITEM_CLS = {DRINK = 'drink', SEEDS = 'seeds'}                    -- everything else: food
local SKIP = {'forbid', 'trader', 'removed', 'garbage_collect', 'in_inventory', 'construction', 'dump', 'hostile',
              'in_building', 'rotten'}
local BLD_CATS = {{'BED', 'bed'}, {'FARM_PLOT', 'farm'}, {'WELL', 'well'}, {'TRADE_DEPOT', 'depot'}}
local CLASSES = {'food', 'drink', 'seeds', 'bed', 'farm', 'well', 'depot', 'exit'}
local VITAL = {'food', 'drink', 'bed'}
-- quickfort build keys that can close a path (dfpilot/bp/validate.py BUILD_KEYS, primitives.BRIDGE_KEYS)
local CLOSERS = {Cw = 'wall', CW = 'wall', CF = 'fort', d = 'door', H = 'hatch', x = 'floodgate', W = 'grate',
                 B = 'bars', s = 'statue', gw = 'bridge', gd = 'bridge', gx = 'bridge', ga = 'bridge', gs = 'bridge'}
local QF_OF = {wall = 'Cw', fort = 'CF', door = 'd', hatch = 'H', floodgate = 'x', grate = 'W', bars = 'B'}
local BKIND = {Door = 'door', Hatch = 'hatch', Bridge = 'bridge', Floodgate = 'floodgate', GrateWall = 'grate',
               BarsVertical = 'bars', Statue = 'statue'}
local GATED = {SIEGE = true, BREACH = true, DRILL = true}

local st      -- persisted m.seal
local mem     -- runtime: caches, results, jobs
local dirty

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

---------------------------------------------------------------- items
local function item_pos(it)
  local a, b, c = dfhack.items.getPosition(it)                    -- Lua API.txt:2055
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end
local function usable_(it)
  local f = it.flags
  for _, k in ipairs(SKIP) do if f[k] then return false end end
  local cont = dfhack.items.getContainer(it)                      -- a forbidden barrel holds nobody's drink
  return not (cont and cont.flags.forbid)
end
local function usable(it)
  local ok, v = pcall(usable_, it)
  return ok and v == true
end
local function stack(it) return int(it.stack_size) or 1 end

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

-- tiles of a burrow (burrows screen count): blocks x 256 tiles, sliced
local function burrow_size(name)
  local b = burrow(name)
  if not b then return 0 end
  local ok, blocks = pcall(dfhack.burrows.listBlocks, b)
  if not ok or type(blocks) ~= 'table' then return 0 end
  local n = 0
  for i = 1, #blocks do
    b = burrow(name)                                              -- never keep a DF pointer across frames
    local blk = b and blocks[i]
    if not blk then break end
    for x = 0, 15 do
      for y = 0, 15 do
        if dfhack.burrows.isAssignedBlockTile(b, blk, x, y) then n = n + 1 end
      end
    end
    spend(96)
  end
  return n
end

local function in_burrow(b, x, y, z)
  P.x, P.y, P.z = x, y, z
  local ok, v = pcall(dfhack.burrows.isAssignedTile, b, P)
  return ok and v == true
end

---------------------------------------------------------------- scheduling
local ORDER = {'audit', 'quick', 'seal', 'perim', 'edges', 'scan', 'paint'}

-- one pending run per job: the earliest tick and the strongest reason (an event beats 'periodic'/'retire', a
-- post-siege diff beats everything), so no request is lost
local WEAK = {periodic = true, retire = true, boot = true}
local function due(name, tick, why, arg)
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

-- one pass over citizens, food/drink/seeds items, beds, farm plots, wells, depots and the edge tiles: walk groups
-- per class (reach) and per-burrow counts (refuge). Pure until the end: the caller commits the result.
local function audit_pass(K)
  local t0 = now_t(K)
  local cits = citizens(K)
  local cg, main = group_counts(cits)
  local R = {tick = t0, main = main, cit = {n = #cits, by = cg}, cls = {}, reps = {}}
  for _, c in ipairs(CLASSES) do R.cls[c] = {n = 0, by = {}, at = {}} end
  local kern, refuge = burrow_names(K)
  local names = {kern}
  if refuge ~= kern then names[#names + 1] = refuge end
  if CFG.interior ~= kern and CFG.interior ~= refuge then names[#names + 1] = CFG.interior end
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
  spend(#cits)
  local gcache = {}                                    -- position -> group (barrels hold many drinks)
  local function pgroup(x, y, z)
    local k = key3(x, y, z)
    local g = gcache[k]
    if g == nil then g = grp(x, y, z) or false; gcache[k] = g end
    return g
  end
  local reps = {food = {}, drink = {}, bed = {}}
  local seen_rep = {food = {}, drink = {}, bed = {}}
  local function rep(cls, k, x, y, z)
    local r = reps[cls]
    if r and not seen_rep[cls][k] and #r < CFG.reps_max then seen_rep[cls][k] = true; r[#r + 1] = {x, y, z} end
  end
  for _, cat in ipairs(ITEM_CATS) do
    local cls = ITEM_CLS[cat] or 'food'
    local i = 0
    while true do
      local v = vec('items', cat)                       -- re-read after every yield
      if not v or i >= #v then break end
      local it = v[i]
      i = i + 1
      if it and usable(it) then
        local x, y, z = item_pos(it)
        if x and x >= 0 then
          local g = pgroup(x, y, z)
          if g and g ~= 0 then
            local n = stack(it)
            local C = R.cls[cls]
            C.n = C.n + n
            add(C.by, g, n)
            if not C.at[g] then C.at[g] = {x, y, z} end
            rep(cls, key3(x, y, z), x, y, z)
            if cls ~= 'seeds' then
              for _, bn in ipairs(names) do
                if B[bn].exists then
                  local b = burrow(bn)
                  if b and in_burrow(b, x, y, z) then B[bn][cls] = B[bn][cls] + n end
                end
              end
            end
          end
        end
      end
      spend(4)
    end
  end
  for _, e in ipairs(BLD_CATS) do
    local v = vec('buildings', e[1])
    for i = 0, vlen(v) - 1 do
      local b = v[i]
      if b and built(b) then
        local g, x, y, z = bgroup(b)
        if g then
          local C = R.cls[e[2]]
          C.n = C.n + 1
          add(C.by, g, 1)
          if not C.at[g] then C.at[g] = {x, y, z} end
          rep(e[2], key3(x, y, z), x, y, z)
          if e[2] == 'bed' or e[2] == 'well' then
            local fld = e[2] == 'bed' and 'beds' or 'wells'
            for _, bn in ipairs(names) do
              local bb = B[bn].exists and burrow(bn)
              if bb and in_burrow(bb, b.centerx, b.centery, b.z) then B[bn][fld] = B[bn][fld] + 1 end
            end
          end
        end
      end
      spend(2)
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
    spend(1)
  end
  for _, n in ipairs(names) do
    if B[n].exists then B[n].tiles = burrow_size(n) end
    burrow_audit(K, #cits, B[n])
  end
  R.reps = reps
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

local function reach_flags(R)
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
  local dead = mem.scan and mem.scan.stairs or {}
  if #dead > 0 then
    local s = dead[1]
    f[#f + 1] = string.format('stairs: %d without counterpart (%s at %d,%d,%d)', #dead, s[4], s[1], s[2], s[3])
  end
  return f
end

---------------------------------------------------------------- CUTOFF blame
-- a closing tile: constructed wall/fortification, or a door/hatch/bridge/floodgate/grate/bars/statue building
local function closer_kind(x, y, z)
  local des, occ = rev(x, y, z)
  if not des then return nil end
  local s = shape(x, y, z)
  if s and (s.shape == 'WALL' or s.shape == 'FORTIFICATION') and s.mat == 'CONSTRUCTION' then
    return s.shape == 'WALL' and 'wall' or 'fort'
  end
  local b = bld_on(x, y, z, occ)
  if b then return BKIND[btype(b) or ''] end
end

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
-- filters them by walk group, so an over-approximation never connects two groups (down a ramp: see bfs)
local function steps(x, y, z, out)
  local n = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then n = n + 1; out[n] = key3(x + dx, y + dy, z) end
    end
  end
  local s = shape(x, y, z)
  local sh = s and s.shape
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
  if not rev(x, y, z) then return false end
  local s = shape(x, y, z)
  return s ~= nil and s.shape == 'RAMP_TOP'
end

-- the tile that cut citizens on group gc from a class held by the groups in `has`
local function blame(K, gc, has, cut_pos)
  for _, k in ipairs(mem.fresh) do                       -- closers completed since the last audit, newest first
    local x, y, z = dec3(k)
    local p = mem.done_info[k] or {}
    if separates(x, y, z, gc, has) then return {x, y, z, p.kind or closer_kind(x, y, z) or '?', p.proj} end
    spend(4)
  end
  local bv = vec('buildings', 'BRIDGE')
  for i = 0, vlen(bv) - 1 do
    local b = bv[i]
    if b then
      local _, s = bstate(b)
      if s == 'up' and ring_separates({b.x1, b.y1, b.z, b.x2, b.y2, b.z}, gc, has) then
        return {b.centerx, b.centery, b.z, 'bridge', nil, bridge = true}
      end
    end
    spend(4)
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
      for i = 1, n do
        local k = nb[i]
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
      spend(4)
    end
  end
  for _, s in ipairs(mem.scan and mem.scan.stairs or {}) do
    if s[6] == gc then return {s[1], s[2], s[3], s[4] .. ' without counterpart'} end
  end
end

local function commit_audit(K, R, cits)
  local t = now_t(K)
  local totals, by_cls = {}, {}
  for _, cls in ipairs(VITAL) do totals[cls] = R.cls[cls].n; by_cls[cls] = R.cls[cls].by end
  local cut = cut_of(R.cit.by, by_cls, totals)
  R.cut = cut
  R.flags = reach_flags(R)
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
             end)(), cut = cut.food + cut.drink + cut.bed,
              stairs = #(mem.scan and mem.scan.stairs or {})})
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

local function job_audit(K)
  local R, cits = audit_pass(K)
  commit_audit(K, R, cits)
  mem.last_audit = now_t(K)
end

-- cheap re-check after a change: the known class positions and the citizens; the full audit only when worse
local function job_quick(K)
  local R = mem.reach
  if not R then due('audit', now_t(K), 'quick'); return end
  local cits = citizens(K)
  local cg = group_counts(cits)
  local by_cls, totals = {}, {}
  for _, cls in ipairs(VITAL) do
    by_cls[cls], totals[cls] = {}, R.cls[cls].n
    for _, p in ipairs(R.reps[cls] or {}) do
      local g = grp(p[1], p[2], p[3])
      if g and g ~= 0 then by_cls[cls][g] = true end
      spend(1)
    end
  end
  local cut = cut_of(cg, by_cls, totals)
  for _, cls in ipairs(VITAL) do
    if cut[cls] > (int(st.cut[cls]) or 0) then due('audit', now_t(K), 'quick:' .. cls); return end
  end
end

---------------------------------------------------------------- map edge (FR-54 sources)
local function job_edges(K)
  local X, Y, Z = map_size()
  local list = {}
  local function try(x, y, z)
    if #list < CFG.edges_max then
      local g = grp(x, y, z)
      if g and g ~= 0 then list[#list + 1] = key3(x, y, z) end
    end
    spend(1)
  end
  for z = Z - 1, 0, -1 do
    for x = 0, X - 1 do try(x, 0, z); try(x, Y - 1, z) end
    for y = 1, Y - 2 do try(0, y, z); try(X - 1, y, z) end
  end
  mem.edges = {tick = now_t(K), list = list}
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
    spend(3)
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
    if ok and r1 then queued, proj = #cells, r2 else K.log('warn', 'seal: repair not queued: %s', tostring(r2 or r1)) end
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
    if not at[r] then reps[#reps + 1] = {x = e.x, y = e.y, z = e.z, ox = e.ox, oy = e.oy, oz = e.oz, d = e.d, n = 1}; at[r] = #reps
    else
      local c = reps[at[r]]
      c.n = c.n + 1
      if e.d < c.d then c.x, c.y, c.z, c.ox, c.oy, c.oz, c.d = e.x, e.y, e.z, e.ox, e.oy, e.oz, e.d end
    end
  end
  table.sort(reps, function(a, b) if a.d ~= b.d then return a.d < b.d end; return key3(a.x, a.y, a.z) < key3(b.x, b.y, b.z) end)
  return reps
end

-- BFS from the citizens of group G over revealed tiles of G: inside tiles always expand, outside tiles until the
-- first map-edge tile is found. Entries = inside tiles next to outside tiles of G. `learned` = blocked tiles next
-- to the visited ones (perimeter candidates).
local function bfs(K, G, sources, X, Y)
  local par, outs, depth, rtop = {}, {}, {}, {}
  local q, head = {}, 1
  local edge_k, partial = nil, false
  local entries, ent_seen, learned = {}, {}, {}
  local function eval(k)                     -- 1 outside, 0 inside, false = hidden or another walk group
    local o = outs[k]
    if o ~= nil then return o end
    local x, y, z = dec3(k)
    local des = rev(x, y, z)
    if not des then outs[k] = false; return false end
    P.x, P.y, P.z = x, y, z
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
  for _, c in ipairs(sources) do
    local k = key3(c.x, c.y, c.z)
    if par[k] == nil and eval(k) ~= false then par[k], depth[k] = -1, 0; q[#q + 1] = k end
  end
  local nb = {}
  local function link(k, nk, ins, expand)
    local o = eval(nk)
    if o == false then return false end
    if ins and o == 1 then entry(k, nk, depth[k]) end
    if not ins and o == 0 then entry(nk, k, depth[k] + 1) end
    if expand and par[nk] == nil then
      par[nk], depth[nk] = k, depth[k] + 1
      q[#q + 1] = nk
    end
    return true
  end
  while head <= #q do
    if head > CFG.bfs_max then partial = true; break end
    local k = q[head]
    head = head + 1
    local x, y, z = dec3(k)
    local ins = outs[k] == 0
    if not edge_k and (x == 0 or y == 0 or x == X - 1 or y == Y - 1) then edge_k = k end
    local expand = ins or not edge_k
    local n = steps(x, y, z, nb)
    for i = 1, n do
      local nk = nb[i]
      if not link(k, nk, ins, expand) and i <= 8 then
        -- down a ramp: a blocked neighbour that is the open top of a ramp one level down
        if rtop[nk] == nil then rtop[nk] = ramp_top(nk) end
        if rtop[nk] then link(k, nk - 16777216, ins, expand) end
      end
    end
    spend(4)
  end
  return {par = par, outs = outs, edge = edge_k, entries = entries, partial = partial, visited = head - 1,
          learned = learned}
end

-- learn the perimeter from a BFS in PEACE: closers next to an inside tile that border an outside tile, and the
-- doors/hatches on the openings
local function learn_perimeter(K, B, reps)
  local t = now_t(K)
  local added = 0
  for _, k in ipairs(B.learned) do
    local x, y, z = dec3(k)
    local kind = closer_kind(x, y, z)
    if kind and kind ~= 'bridge' then
      local inner, outer = false, false
      for dy = -1, 1 do
        for dx = -1, 1 do
          local o = B.outs[key3(x + dx, y + dy, z)]
          if o == 0 then inner = true elseif o == 1 then outer = true
          elseif o == nil and (dx ~= 0 or dy ~= 0) then
            local des = rev(x + dx, y + dy, z)
            if des and des.outside then outer = true end
          end
        end
      end
      if inner and outer and perim_add(kstr(x, y, z), {k = kind, src = 'seal'}, t) then added = added + 1 end
    end
    spend(2)
  end
  for _, r in ipairs(reps) do
    local des, occ = rev(r.x, r.y, r.z)
    local b = des and bld_on(r.x, r.y, r.z, occ)
    local kind = b and BKIND[btype(b) or '']
    if kind and kind ~= 'bridge' and perim_add(kstr(r.x, r.y, r.z), {k = kind, src = 'seal'}, t) then added = added + 1 end
  end
  if added > 0 then K.log('info', 'seal: %d perimeter pieces learned', added) end
end

local function job_seal(K, why)
  local t0 = now_t(K)
  if not mem.edges then job_edges(K) end
  local X, Y = map_size()
  local cits = citizens(K)
  local res = {tick = t0, why = why or '', sealed = false, routes = 0, openings = {}}
  if #cits == 0 then res.msg = 'no citizen on a revealed walkable tile'; mem.seal = res; return end
  local cg = group_counts(cits)
  local E = {}
  for _, k in ipairs(mem.edges.list) do
    local x, y, z = dec3(k)
    local g = grp(x, y, z)
    if g and g ~= 0 and not E[g] then E[g] = k end
    spend(1)
  end
  local leak = {}
  for _, g in ipairs(sorted_keys(cg)) do if E[g] then leak[#leak + 1] = g end end
  local mode = K.mode()
  local expect = bridges_expect_sealed(K)
  if #leak == 0 then
    res.sealed, res.msg = true, 'seal verified: no route'
  else
    local G = leak[1]
    for _, g in ipairs(leak) do if cg[g] > cg[G] then G = g end end
    local src = {}
    for _, c in ipairs(cits) do if c.g == G then src[#src + 1] = c end end
    local B = bfs(K, G, src, X, Y)
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
        res.msg = string.format('LEAK at %d,%d,%d (%s %s)%s', first[1], first[2], first[3], tostring(bt), tostring(bs),
                                res.first.missing and (', ' .. res.first.missing .. ' missing') or '')
      else
        res.first = {pos = {src[1].x, src[1].y, src[1].z}, open = true}
        res.msg = string.format('LEAK: open route from %d,%d,%d to the map edge without a roofed tile',
                                src[1].x, src[1].y, src[1].z)
      end
    else
      res.msg = string.format('LEAK: group %d reaches the map edge, route not traced (%s)', G,
                              B.partial and 'search limit' or 'unrevealed or climbing')
    end
    res.msg = res.msg .. string.format('; %d independent route%s', res.routes, res.routes == 1 and '' or 's')
    if mode == 'PEACE' then learn_perimeter(K, B, reps) end
  end
  res.expect = expect
  local prev = mem.seal
  mem.seal = res
  local pos = res.first and res.first.pos or nil
  if not res.sealed and expect then
    K.emit('SEAL_LEAK', 'A', trunc(res.msg, 200), {routes = res.routes, pos = pos, bld = res.first and res.first.bld,
           state = res.first and res.first.state, why = trunc(why or '', 40)})
  elseif why ~= 'inspect' and (why ~= 'periodic' or not prev or prev.sealed ~= res.sealed or prev.routes ~= res.routes) then
    K.emit('SEAL', 'B', trunc(res.msg, 200), {routes = res.routes, pos = pos, why = trunc(why or '', 40),
           sealed = res.sealed and 1 or 0})
  end
  st.seal = {t = t0, sealed = res.sealed and 1 or 0, routes = res.routes}
  dirty = true
end

---------------------------------------------------------------- scan: stairs without counterpart, interior tiles
local function box_of(K, cits)
  local bb
  local function grow(x, y, z)
    if not bb then bb = {x, y, z, x, y, z}
    else
      bb[1], bb[2], bb[3] = math.min(bb[1], x), math.min(bb[2], y), math.min(bb[3], z)
      bb[4], bb[5], bb[6] = math.max(bb[4], x), math.max(bb[5], y), math.max(bb[6], z)
    end
  end
  for _, c in ipairs(cits) do grow(c.x, c.y, c.z) end
  local v = vec('buildings', 'BED')
  for i = 0, vlen(v) - 1 do local b = v[i]; if b then grow(b.centerx, b.centery, b.z) end end
  for _, r in ipairs(mem.seal and mem.seal.openings or {}) do grow(r.pos[1], r.pos[2], r.pos[3]) end
  local man = K.manifest()
  for _, kind in ipairs({'civ', 'mil'}) do
    local s = type(man.stairs) == 'table' and man.stairs[kind]
    for _, c in ipairs(type(s) == 'table' and s or {}) do grow(c[1], c[2], c[3]); grow(c[1], c[2], c[4]) end
  end
  if not bb then return nil end
  local X, Y, Z = map_size()
  local m = CFG.scan_margin
  local b = {math.max(0, bb[1] - m[1]), math.max(0, bb[2] - m[2]), math.max(0, bb[3] - m[3]),
             math.min(X - 1, bb[4] + m[1]), math.min(Y - 1, bb[5] + m[2]), math.min(Z - 1, bb[6] + m[3])}
  while (b[4] - b[1] + 1) * (b[5] - b[2] + 1) * (b[6] - b[3] + 1) > CFG.scan_max and b[6] > b[3] do
    b[3], b[6] = b[3] + 1, b[6] - 1                       -- too big: fewer levels around the middle
  end
  return b
end

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

local function job_scan(K, paint)
  local cits = citizens(K)
  local _, main = group_counts(cits)
  local b = box_of(K, cits)
  local res = {tick = now_t(K), stairs = {}, box = b}
  if not b then mem.scan = res; return end
  local ex = paint and excluded(K) or {}
  local inner = paint and main and {} or nil
  for z = b[3], b[6] do
    for y = b[2], b[5] do
      for x = b[1], b[4] do
        local des = rev(x, y, z)
        if des then
          local s = shape(x, y, z)
          local sh = s and s.shape
          if sh and (UP[sh] or DOWN[sh]) and #res.stairs < 40 then
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
            if why then
              local kind = ({STAIR_UP = 'up stair', STAIR_DOWN = 'down stair', STAIR_UPDOWN = 'up/down stair'})[sh]
              res.stairs[#res.stairs + 1] = {x, y, z, kind, why, grp(x, y, z) or 0}
            end
          end
          if inner and not des.outside and #inner < CFG.interior_max then
            P.x, P.y, P.z = x, y, z
            if dfhack.maps.getWalkableGroup(P) == main then
              local skip = false
              for _, e in ipairs(ex) do
                if x >= e[1] and x <= e[4] and y >= e[2] and y <= e[5] and z >= e[3] and z <= e[6] then skip = true; break end
              end
              if not skip then inner[#inner + 1] = {x, y, z} end
            end
          end
          spend(2)
        else
          spend(1)
        end
      end
    end
  end
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
    local sig = want .. '>' .. tostring(pick)
    if mem.fail_sig ~= sig or t - (mem.fail_t or -CFG.fail_every) >= CFG.fail_every then
      mem.fail_sig, mem.fail_t = sig, t
      local au = mem.audit and mem.audit.burrows or {}
      local a = pick and au[pick]
      K.emit('REFUGE_FAIL', 'A', trunc(string.format('alert burrow %s refused (%s): %s', want, why,
             pick and ('confining to ' .. pick) or 'no confinement, the whole fort'), 200),
             {burrow = want, fallback = pick or '', why = trunc(why, 120), tiles = a and a.tiles or 0,
              inside = a and a.inside or 0, mode = mode})
    end
  end
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
  if n > 0 and (not mem.reach or t - mem.reach.tick > CFG.quick_min) then due('audit', t, 'before ' .. tostring(proj)) end
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
  audit = function(K) job_audit(K) end,
  quick = function(K) job_quick(K) end,
  seal = function(K, d) job_seal(K, d.why) end,
  perim = function(K, d) job_perim(K, d.why) end,
  edges = function(K) job_edges(K) end,
  scan = function(K, d) job_scan(K, d.arg == true) end,
  paint = function(K) job_paint(K) end,
}

local function schedule_periodic(K, t)
  local mode = K.mode()
  local every = mode == 'PEACE' and CFG.audit_every or CFG.audit_alert
  if t - (mem.last_audit or -every) >= every then due('audit', t, 'periodic') end
  if t - (mem.seal and mem.seal.tick or -CFG.seal_every) >= CFG.seal_every then due('seal', t, 'periodic') end
  if t - (mem.edges and mem.edges.tick or -CFG.edges_every) >= CFG.edges_every then due('edges', t, 'periodic') end
  if t - (mem.scan and mem.scan.tick or -CFG.scan_every) >= CFG.scan_every then due('scan', t, 'periodic') end
  if mode == 'PEACE' and t - (mem.retire_t or -CFG.seal_every) >= CFG.seal_every then
    mem.retire_t = t
    due('perim', t, 'retire')
  end
end

local function next_job(t)
  for _, name in ipairs(ORDER) do
    local d = mem.due[name]
    if d and d.tick <= t then mem.due[name] = nil; return name, d end
  end
end

local function run_jobs(K, t)
  mem.left = CFG.work
  while mem.left > 0 do
    if not mem.co then
      local name, d = next_job(t)
      if not name then return end
      mem.co_name = name
      mem.co = coroutine.create(function() JOBS[name](K, d) end)
    end
    local ok, err = coroutine.resume(mem.co)
    if not ok then
      local name = mem.co_name
      mem.co, mem.co_name = nil, nil
      error('seal job ' .. tostring(name) .. ': ' .. tostring(err), 0)
    end
    if coroutine.status(mem.co) == 'dead' then mem.co, mem.co_name = nil, nil
    else return 'more' end
  end
  return mem.co and 'more' or nil
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.seal')
  p = type(p) == 'table' and p or {}
  st = {v = 2, perim = {}, cut = {}, req = {}, hostile = int(p.hostile), painted = int(p.painted),
        flag_sig = type(p.flag_sig) == 'string' and p.flag_sig or nil}
  for k, piece in pairs(type(p.perim) == 'table' and p.perim or {}) do
    if type(k) == 'string' and type(piece) == 'table' and type(piece.k) == 'string' then st.perim[k] = piece end
  end
  for _, cls in ipairs(VITAL) do st.cut[cls] = int(type(p.cut) == 'table' and p.cut[cls]) or 0 end
  for k, v in pairs(type(p.req) == 'table' and p.req or {}) do if int(v) then st.req[k] = int(v) end end
  if type(p.swap) == 'table' and int(p.swap.since) then st.swap = {since = int(p.swap.since)} end
  if type(p.seal) == 'table' then st.seal = p.seal end
  mem = {tt = {}, due = {}, pend = {}, npend = 0, fresh = {}, done_info = {}, left = 0}
  perim_count()
  dirty = true
  local t = now_t(K)
  due('edges', t, 'boot')
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
  if not mem.co then publish(K) end
  save(K)
  return r
end

function M.state(K) return mem and mem.pub and {alert = mem.pub} or {} end

M.on.MODE = function(K, ev)
  local t = ev.tick or now_t(K)
  local to, from = ev.to, ev.from
  if to ~= 'PEACE' and from == 'PEACE' then due('audit', t, 'mode ' .. to) end   -- a fresh refuge audit
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
M.on['EV:PROJECT_DONE'] = function(K) due('scan', now_t(K), 'project') end
M.on.UNLOAD = function(K) save(K) end

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

M.inspect.reach = function(K, args)
  local t = now_t(K)
  if not mem.reach or (args.key == 'refresh' and mem.co_name ~= 'audit') then sync(job_audit, K) end
  local R = mem.reach
  local cls = {}
  for _, c in ipairs(CLASSES) do
    local C = R.cls[c]
    local on = R.main and C.by[R.main] or 0
    local at
    for g, p in pairs(C.at) do if g ~= R.main and not at then at = {g, p[1], p[2], p[3]} end end
    cls[c] = {n = C.n, main = on, off = C.n - on, groups = pairs_of(C.by), off_at = at}
  end
  local stairs = {}
  for i, s in ipairs(mem.scan and mem.scan.stairs or {}) do
    if i > 12 then break end
    stairs[i] = {s[1], s[2], s[3], s[4], s[5]}
  end
  return true, string.format('reach %s (age %d): %s', R.main and ('main group ' .. R.main) or 'no citizens',
         t - R.tick, #R.flags > 0 and R.flags[1] or 'every class on the citizens\' group'),
         {tick = R.tick, main = R.main or 0, cit = {n = R.cit.n, groups = pairs_of(R.cit.by)}, classes = cls,
          cut = R.cut, flags = R.flags, stairs = stairs, blame = R.blame}
end

M.inspect.entrances = function(K, args)
  if not mem.seal or args.key == 'refresh' then
    if mem.co_name ~= 'seal' then sync(job_seal, K, 'inspect') end
  end
  local s = mem.seal
  return true, s.msg or '?', {tick = s.tick, why = s.why, sealed = s.sealed, routes = s.routes, first = s.first,
                              openings = s.openings, edge = s.edge, len = s.len, via = s.via, partial = s.partial,
                              expect_sealed = s.expect}
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
          for _, l in ipairs(lv) do if l.pos[1] == p[1] and l.pos[2] == p[2] and l.pos[3] == p[3] then found = true end end
          if not found then
            local here
            for _, l in ipairs(levers) do if l.pos[1] == p[1] and l.pos[2] == p[2] and l.pos[3] == p[3] then here = l end end
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
  return true, string.format('%d perimeter pieces', mem.perim_n or 0),
         {n = mem.perim_n or 0, by = by, pieces = list,
          diff = d and {tick = d.tick, why = d.why, gone = {table.unpack(d.gone, 1, math.min(#d.gone, 40))}} or nil}
end

M.inspect.refuge = function(K, args)
  if not mem.audit or args.key == 'refresh' then
    if mem.co_name ~= 'audit' then sync(job_audit, K) end
  end
  local au = mem.audit
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
  return true, string.format('alert %s: %s, %d tiles, %d/%d inside%s', K.mode(), p.burrow ~= '' and p.burrow or 'no confinement',
         p.tiles, p.inside, au.cit, p.why ~= '' and (' (' .. p.why .. ')') or ''),
         {tick = au.tick, cit = au.cit, burrows = b, choice = choice, swap = st.swap, quiet = quiet(K) == math.huge and -1 or quiet(K)}
end

return M
