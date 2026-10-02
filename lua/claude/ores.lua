-- claude/ores [zmin zmax] [--budget ms]  - reports ORE and gem veins on already DISCOVERED tiles (does not reveal anything hidden)
-- Output: count and an example location per material; marks ores with metal content.
-- HEAVY: runs in the game's main thread over every map block of the z range (whole map: estimated 20+ s, BUG-415).
-- Levels are scanned from the top down; after --budget milliseconds (default 2000) the scan stops after the current
-- level and the answer has unvollstaendig=true + 'weiter' (the command that continues below). Not for polling.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local mx, my, mz = dfhack.maps.getTileSize()
local args, budget = {}, 2000
do
  local raw = { ... }
  local i = 1
  while i <= #raw do
    if raw[i] == '--budget' then budget = tonumber(raw[i + 1]) or budget i = i + 2
    else args[#args + 1] = raw[i] i = i + 1 end
  end
end
local zmin = math.max(0, math.tointeger(tonumber(args[1]) or 0) or 0)
local zmax = math.min(mz - 1, math.tointeger(tonumber(args[2]) or (mz - 1)) or (mz - 1))
local function now_ms()
  local ok, t = pcall(dfhack.getTickCount)
  if ok and type(t) == 'number' then return t end
  return os.clock() * 1000
end
local found = {}
local function scan_block(blk)
  for _, ev in ipairs(blk.block_events) do
    if df.block_square_event_mineralst:is_instance(ev) then
      local raw = df.inorganic_raw.find(ev.inorganic_mat)
      if raw then
        local ore = #raw.metal_ore.mat_index > 0
        local metal = ''
        if ore then
          local names = {}
          for _, mi in ipairs(raw.metal_ore.mat_index) do
            local m = df.inorganic_raw.find(mi)
            if m then names[#names + 1] = m.id end
          end
          metal = table.concat(names, '/')
        end
        for ey = 0, 15 do
          local bits = ev.tile_bitmask.bits[ey]
          if bits ~= 0 then
            for ex = 0, 15 do
              if bits & (1 << ex) ~= 0 then
                local x, y = blk.map_pos.x + ex, blk.map_pos.y + ey
                local des = blk.designation[ex][ey]
                if not des.hidden then
                  local k = raw.id
                  local f = found[k] or { n = 0, ore = ore, metal = metal, ex = x .. ',' .. y .. ',' .. blk.map_pos.z }
                  f.n = f.n + 1
                  found[k] = f
                end
              end
            end
          end
        end
      end
    end
  end
end

local t0, stopped_at = now_ms(), nil
for bz = zmax, zmin, -1 do
  for bx = 0, mx // 16 - 1 do
    for by = 0, my // 16 - 1 do
      local blk = dfhack.maps.getBlock(bx, by, bz)
      if blk then scan_block(blk) end
    end
  end
  if bz > zmin and now_ms() - t0 > budget then stopped_at = bz break end
end

local out, ores = {}, {}
for k, f in pairs(found) do
  local line = k .. ': ' .. f.n .. ' Kacheln, Beispiel ' .. f.ex .. (f.ore and (' ERZ -> ' .. f.metal) or '')
  out[#out + 1] = line
  if f.ore then ores[#ores + 1] = line end
end
table.sort(out)
local res = { erze_gefunden = #ores, erze = ores, alle_adern = out, z_bereich = { stopped_at or zmin, zmax },
              ms = math.floor(now_ms() - t0) }
if stopped_at then
  res.unvollstaendig = true
  res.weiter = ('claude/ores %d %d'):format(zmin, stopped_at - 1)
end
util.emit(res)
