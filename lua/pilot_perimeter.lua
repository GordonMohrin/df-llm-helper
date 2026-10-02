-- claude/pilot_perimeter scan|start cx cy cz zmin zmax [budget] | result            (df-llm-helper spec v3-01, LIVE-UNTESTED)
-- Accesses from outside into the fort (algorithm of lua/claude/zugaenge.lua, JSON output):
--   1. multi-source BFS from every walkable tile with designation.outside (levels zmin..zmax)
--   2. entry = reached walkable INSIDE tile that has a reached outside tile as move neighbor
--   3. two inside-only BFS from the core point (cx,cy,cz): with and without trap tiles
--      -> per entry: core = leads to the core, notrap = reaches the core while bypassing all traps
-- df-llm-helper clusters the entries, applies the allow-list and proposes walls (pure logic in Python).
-- scan:   synchronous, prints {"ok":true,"done":true,"entries":[[x,y,z,core,notrap],...],"traps":n,"visited":n,"ms":t}
-- start:  same work in chunks of <budget> nodes per frame (dfhack.timeout) -> the main thread never blocks for long
--         (the prototype held it ~10 s); the result goes to <df-llm-helper home>/tools/out/perimeter_scan.json
-- result: prints that file ({"done":false} while running).
-- Read only. Unrevealed tiles are never walked (they are not walkable here).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local json = require('json')

local a = { ... }
local cmd = a[1] or 'scan'
local function n(i) return tonumber(a[i]) end
local MAP = df.global.world.map
local XM, YM, ZM = MAP.x_count, MAP.y_count, MAP.z_count
local SHAPE = df.tiletype_shape
local FLOORISH = {}
for _, nm in ipairs({ 'FLOOR', 'BOULDER', 'PEBBLES', 'SHRUB', 'SAPLING', 'TWIG', 'BROOK_BED', 'BROOK_TOP',
                      'TRUNK_BRANCH' }) do
  if SHAPE[nm] then FLOORISH[SHAPE[nm]] = true end
end
local OUTFILE = util.home() .. '/tools/out/perimeter_scan.json'

-- building tile that blocks walking (well, statue ...): block occupancy Well/Obstacle (= walk group 0 in DF 53).
-- Workshops/furnaces are NOT blocking in DF (occupancy 'Passable', walk group of the fort; dwarves stand on them).
local OCC = df.tile_building_occ
local function blocked_by_building(x, y, z)
  if not OCC then return false end
  local blk = dfhack.maps.getTileBlock(x, y, z)
  if not blk then return false end
  local o = blk.occupancy[x % 16][y % 16].building
  return o == OCC.Obstacle or o == OCC.Well
end

-- tile classes (same encoding as df_llm_helper/features/_grid.py, reduced to what the path logic needs)
local function tch(x, y, z)
  if x < 0 or y < 0 or z < 0 or x >= XM or y >= YM or z >= ZM then return '#' end
  local d = dfhack.maps.getTileFlags(x, y, z)
  if not d or d.hidden then return '?' end
  if d.flow_size > 0 then return '~' end
  if blocked_by_building(x, y, z) then return 'W' end
  local tt = dfhack.maps.getTileType(x, y, z)
  local at = tt and df.tiletype.attrs[tt]
  if not at then return '#' end
  local sh, out = at.shape, d.outside
  if sh == SHAPE.RAMP then return out and '/' or '^' end
  if sh == SHAPE.STAIR_UPDOWN then return out and 'x' or 'X' end
  if sh == SHAPE.STAIR_UP then return '<' end
  if sh == SHAPE.STAIR_DOWN then return '>' end
  if FLOORISH[sh] then
    if dfhack.buildings and dfhack.buildings.findAtTile then
      local b = dfhack.buildings.findAtTile(x, y, z)
      if b and b:getType() == df.building_type.Trap then return 'T' end
    end
    return out and ',' or '.'
  end
  return '#'
end
local WALK = { ['.'] = true, [','] = true, X = true, x = true, ['<'] = true, ['>'] = true, ['^'] = true, ['/'] = true,
               D = true, T = true }
local OUT = { [','] = true, x = true, ['/'] = true }
local UP = { X = true, x = true, ['<'] = true }
local DOWN = { X = true, x = true, ['>'] = true }
local RAMP = { ['^'] = true, ['/'] = true }

local function new_job(cx, cy, cz, zmin, zmax, budget)
  local J = { cx = cx, cy = cy, cz = cz, zmin = math.max(0, zmin), zmax = math.min(ZM - 1, zmax),
              budget = budget or 20000, phase = 'seed', zc = math.max(0, zmin), cache = {}, seen = {}, q = {}, qi = 1,
              visited = 0, t0 = os.clock() }
  J.zc = J.zmin
  local function key(x, y, z) return (z * YM + y) * XM + x end
  local function unkey(k) local x = k % XM local r = (k - x) // XM return x, r % YM, r // YM end
  local function ch(x, y, z)
    local k = key(x, y, z)
    local c = J.cache[k]
    if not c then c = tch(x, y, z) J.cache[k] = c end
    return c
  end
  local function inz(z) return z >= J.zmin and z <= J.zmax end
  -- move neighbors (mirrors Grid.neighbors in _grid.py)
  local function neighbors(x, y, z)
    local res, c = {}, ch(x, y, z)
    for dy = -1, 1 do for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        if WALK[ch(x + dx, y + dy, z)] then res[#res + 1] = key(x + dx, y + dy, z) end
      end
    end end
    if UP[c] and z + 1 < ZM and DOWN[ch(x, y, z + 1)] then res[#res + 1] = key(x, y, z + 1) end
    if DOWN[c] and z > 0 and UP[ch(x, y, z - 1)] then res[#res + 1] = key(x, y, z - 1) end
    for dy = -1, 1 do for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        if RAMP[c] and z + 1 < ZM and WALK[ch(x + dx, y + dy, z + 1)] then res[#res + 1] = key(x + dx, y + dy, z + 1) end
        if z > 0 and RAMP[ch(x + dx, y + dy, z - 1)] then res[#res + 1] = key(x + dx, y + dy, z - 1) end
      end
    end end
    return res
  end
  -- generic chunked BFS: ok(c) decides which tiles may be entered
  local function bfs_step(seen, q, ok)
    local work = 0
    while J.qi <= #q and work < J.budget do
      local x, y, z = unkey(q[J.qi])
      J.qi = J.qi + 1
      work = work + 1
      for _, k in ipairs(neighbors(x, y, z)) do
        if not seen[k] then
          local nx, ny, nz = unkey(k)
          if inz(nz) and ok(ch(nx, ny, nz)) then seen[k] = true q[#q + 1] = k end
        end
      end
    end
    J.visited = J.visited + work
    return J.qi > #q
  end
  local function inside(c) return WALK[c] and not OUT[c] end
  local function notrap(c) return inside(c) and c ~= 'T' end

  -- one bounded unit of work; returns true when finished
  function J.step()
    if J.phase == 'seed' then
      for _ = 1, 2 do
        if J.zc > J.zmax then break end
        local z = J.zc
        for y = 0, YM - 1 do for x = 0, XM - 1 do
          local d = dfhack.maps.getTileFlags(x, y, z)
          if d and d.outside and not d.hidden then
            local c = ch(x, y, z)
            if WALK[c] and OUT[c] then
              local k = key(x, y, z)
              if not J.seen[k] then J.seen[k] = true J.q[#J.q + 1] = k end
            end
          end
        end end
        J.zc = J.zc + 1
      end
      if J.zc > J.zmax then J.phase = 'out' J.qi = 1 end
      return false
    elseif J.phase == 'out' then
      if bfs_step(J.seen, J.q, function(c) return WALK[c] end) then
        J.entries = {}
        -- Enklaven-Filter (bau J113): ein Aussen-Nachbar zaehlt nur, wenn seine zusammenhaengende Aussenflaeche >= MINCOMP Kacheln hat
        -- (abgemauerte Terrassen mit Himmelsflag sind keine Aussenwelt); identisch zu lua/claude/zugaenge.lua (MINCOMP 3000)
        local MINCOMP, compmemo = 3000, {}
        local function real_outside(startk)
          if compmemo[startk] ~= nil then return compmemo[startk] end
          local seenc, qc, qi, big = { [startk] = true }, { startk }, 1, false
          while qc[qi] do
            local ck = qc[qi]; qi = qi + 1
            if #qc >= MINCOMP then big = true break end
            local cx, cy, cz = unkey(ck)
            for _, nk in ipairs(neighbors(cx, cy, cz)) do
              if not seenc[nk] then
                local nx, ny, nz = unkey(nk)
                if OUT[ch(nx, ny, nz)] then seenc[nk] = true qc[#qc + 1] = nk end
              end
            end
          end
          for k2 in pairs(seenc) do compmemo[k2] = big end
          return big
        end
        for k in pairs(J.seen) do
          local x, y, z = unkey(k)
          if not OUT[ch(x, y, z)] then
            for _, nk in ipairs(neighbors(x, y, z)) do
              local nx, ny, nz = unkey(nk)
              if J.seen[nk] and OUT[ch(nx, ny, nz)] and real_outside(nk) then J.entries[#J.entries + 1] = k break end
            end
          end
        end
        J.phase = 'core'
        local ck = key(J.cx, J.cy, J.cz)
        J.core, J.cq, J.qi = {}, {}, 1
        if inside(ch(J.cx, J.cy, J.cz)) then J.core[ck] = true J.cq[1] = ck end
      end
      return false
    elseif J.phase == 'core' then
      if bfs_step(J.core, J.cq, inside) then
        J.phase = 'notrap'
        local ck = key(J.cx, J.cy, J.cz)
        J.nt, J.nq, J.qi = {}, {}, 1
        if notrap(ch(J.cx, J.cy, J.cz)) then J.nt[ck] = true J.nq[1] = ck end
      end
      return false
    elseif J.phase == 'notrap' then
      if bfs_step(J.nt, J.nq, notrap) then J.phase = 'done' end
      return J.phase == 'done'
    end
    return true
  end

  function J.result()
    local list, traps = {}, 0
    for _, k in ipairs(J.entries or {}) do
      local x, y, z = unkey(k)
      list[#list + 1] = { x, y, z, J.core[k] and 1 or 0, J.nt[k] and 1 or 0 }
    end
    table.sort(list, function(p, q)
      if p[3] ~= q[3] then return p[3] < q[3] end
      if p[2] ~= q[2] then return p[2] < q[2] end
      return p[1] < q[1]
    end)
    for _, c in pairs(J.cache) do if c == 'T' then traps = traps + 1 end end
    return { ok = true, done = true, core = { J.cx, J.cy, J.cz }, z_range = { J.zmin, J.zmax }, entries = list,
             traps = traps, visited = J.visited, ms = math.floor((os.clock() - J.t0) * 1000) }
  end
  return J
end

local function write_file(t)
  if dfhack.filesystem and dfhack.filesystem.mkdir_recursive then
    dfhack.filesystem.mkdir_recursive(util.home() .. '/tools/out')
  end
  local f = io.open(OUTFILE, 'w')
  if not f then return false end
  f:write(json.encode(t))
  f:close()
  return true
end

local function read_file()
  local f = io.open(OUTFILE, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

if cmd == 'scan' or cmd == 'start' then
  local cx, cy, cz, zmin, zmax = n(2), n(3), n(4), n(5), n(6)
  if not (cx and cy and cz and zmin and zmax) then
    util.emit({ ok = false, error = cmd .. ' cx cy cz zmin zmax [budget]' })
    return
  end
  local J = new_job(cx, cy, cz, zmin, zmax, n(7))
  if cmd == 'scan' then
    while not J.step() do end
    util.emit(J.result())
    return
  end
  local prev = read_file()
  if prev then
    local ok, p = pcall(json.decode, prev)
    if ok and type(p) == 'table' and p.done == false and p.started and os.time() - p.started < 300 then
      util.emit({ ok = false, error = 'scan already running', started = p.started })
      return
    end
  end
  write_file({ ok = true, done = false, started = os.time() })
  local function tick()
    local ok, fin = pcall(J.step)
    if not ok then write_file({ ok = false, done = true, error = tostring(fin) }) return end
    if fin then write_file(J.result()) else dfhack.timeout(1, 'frames', tick) end
  end
  dfhack.timeout(1, 'frames', tick)
  util.emit({ ok = true, started = true, file = OUTFILE })
elseif cmd == 'result' then
  local s = read_file()
  if s then print(s) else util.emit({ ok = false, error = 'no scan result' }) end
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_perimeter scan|start cx cy cz zmin zmax [budget] | result' })
end
