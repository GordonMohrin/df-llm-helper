-- claude/ores  - reports ORE and gem veins on already DISCOVERED tiles (does not reveal anything hidden)
-- Output: count and an example location per material; marks ores with metal content.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local mx, my, mz = dfhack.maps.getTileSize()
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

for bz = 0, mz - 1 do
  for bx = 0, mx // 16 - 1 do
    for by = 0, my // 16 - 1 do
      local blk = dfhack.maps.getBlock(bx, by, bz)
      if blk then scan_block(blk) end
    end
  end
end

local out, ores = {}, {}
for k, f in pairs(found) do
  local line = k .. ': ' .. f.n .. ' Kacheln, Beispiel ' .. f.ex .. (f.ore and (' ERZ -> ' .. f.metal) or '')
  out[#out + 1] = line
  if f.ore then ores[#ores + 1] = line end
end
table.sort(out)
util.emit({ erze_gefunden = #ores, erze = ores, alle_adern = out })
