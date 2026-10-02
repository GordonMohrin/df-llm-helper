--@ module = true
-- claude/erzdig <ORE|ALL> <zmin> <zmax> [max] [--dry]   -- ore supply: designates DISCOVERED, reachable ore wall tiles (shape WALL only).
--   ORE = HEMATITE | TETRAHEDRITE | GALENA | ALL (all metal ores) | GEMS (all gem veins, IS_GEM) | exact material ID. Fair play: only tiles with hidden=false (nothing uncovered).
--   Safeguards: never the fort boxes of bau (config.LAYOUT_BOXEN), never water_table, never z < config.dig_min_z() (exception only via config.DIG_CAVERN_Z; run 4: none
--   with explicit zmin), neighbor tile must be walkable AND in the same walk group as the fort corridor (no walling in of miners).
--   Prefers tiles near the fort center; max (default 60) limits the queue.
-- claude/erzdig purge  -- removes invalid dig designations (dig ~= No on tiles that are not WALL; except j/h/UpStair chain tiles).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local DD = df.tile_dig_designation

local function shape(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  return tt and df.tiletype_shape[df.tiletype.attrs[tt].shape] or nil
end
local function walkable(x, y, z)
  local sh = shape(x, y, z)
  return sh and (sh == 'FLOOR' or sh:find('STAIR') ~= nil or sh:find('RAMP') ~= nil)
end
function in_fortbox(x, y, z) return cfg.in_layout(x, y, z) end -- Run 4: config.LAYOUT_BOXEN (bau), empty until LAYOUT-run4.md exists

-- Remove invalid designations (floor/sapling/open with default/ramp/UpStair..., channel on floor is valid)
function purge(zmin, zmax)
  local mx, my = dfhack.maps.getTileSize()
  local n, kept = 0, 0
  for z = zmin or cfg.dig_min_z(cfg.aquifer_seen()), zmax or cfg.SURFACE_Z do
    for bx = 0, mx // 16 - 1 do for by = 0, my // 16 - 1 do
      local b = dfhack.maps.getBlock(bx, by, z)
      -- Speed (30.09.): only blocks with flags.designated (enum lookup/tile loop over 2160 blocks cost 0.5 s per run)
      if b and b.flags.designated then for i = 0, 15 do for j = 0, 15 do
        local d = b.designation[i][j]
        if d.dig ~= DD.No then
          local sh = df.tiletype_shape[df.tiletype.attrs[b.tiletype[i][j]].shape]
          local ok = (sh == 'WALL' or ((d.dig == DD.DownStair or d.dig == DD.Channel) and sh == 'FLOOR')) and not cfg.is_sperre(b.map_pos.x + i, b.map_pos.y + j, z)
          -- Shaft barriers (claude/schacht): do not delete the deconstruction marker on the head wall/wall plugs
          if cfg.is_schacht_arbeit(b.map_pos.x + i, b.map_pos.y + j, z) then ok = true end
          if not ok then d.dig = DD.No n = n + 1 else kept = kept + 1 end
        end
      end end end
    end end
  end
  -- Remove dig jobs (type Dig) on tiles that are no longer wall (floor/sapling/open)
  local jobs = 0
  local l = df.global.world.jobs.list.next
  local kill = {}
  while l do
    local j = l.item
    if j and j.job_type == df.job_type.Dig and j.pos.z >= (zmin or 0) then
      local sh = shape(j.pos.x, j.pos.y, j.pos.z)
      if sh and sh ~= 'WALL' and not cfg.is_schacht_arbeit(j.pos.x, j.pos.y, j.pos.z) then kill[#kill + 1] = j end
    end
    l = l.next
  end
  for _, j in ipairs(kill) do if dfhack.job.removeJob(j) then jobs = jobs + 1 end end
  return n, kept, jobs
end

function run(ore, zmin, zmax, max, dry)
  local mx, my = dfhack.maps.getTileSize()
  local anc = cfg.anchor()
  local gref = dfhack.maps.getWalkableGroup(xyz2pos(anc.x, anc.y, anc.z))
  local cands = {}
  for bz = zmin, zmax do
    if bz >= cfg.dig_min_z(cfg.aquifer_seen()) or (cfg.DIG_CAVERN_Z and bz < cfg.DIG_CAVERN_Z) then
      for bx = 0, mx // 16 - 1 do for by = 0, my // 16 - 1 do
        local blk = dfhack.maps.getBlock(bx, by, bz)
        if blk then for _, ev in ipairs(blk.block_events) do
          if df.block_square_event_mineralst:is_instance(ev) then
            local raw = df.inorganic_raw.find(ev.inorganic_mat)
            -- GEMS (30.09. pass 7): gem veins (material.flags.IS_GEM) for the mood stock/jeweler; otherwise metal ores (ALL) or exact ID
            if raw and ((ore == 'GEMS' and raw.material.flags.IS_GEM)
                or (#raw.metal_ore.mat_index > 0 and (ore == 'ALL' or raw.id == ore))
                or (ore ~= 'ALL' and ore ~= 'GEMS' and raw.id == ore)) then
              for ey = 0, 15 do local bits = ev.tile_bitmask.bits[ey]
                if bits ~= 0 then for ex = 0, 15 do if bits & (1 << ex) ~= 0 then
                  local d = blk.designation[ex][ey]
                  local x, y = blk.map_pos.x + ex, blk.map_pos.y + ey
                  if not d.hidden and d.dig == DD.No and not d.water_table and not in_fortbox(x, y, bz) and not cfg.is_sperre(x, y, bz)
                     and df.tiletype_shape[df.tiletype.attrs[blk.tiletype[ex][ey]].shape] == 'WALL' then
                    local ok = false
                    for dx = -1, 1 do for dy = -1, 1 do
                      if not ok and walkable(x + dx, y + dy, bz) and dfhack.maps.getWalkableGroup(xyz2pos(x + dx, y + dy, bz)) ~= 0 then
                        -- same group as the fort? (caverns are connected via shaft D; otherwise do not designate)
                        if dfhack.maps.getWalkableGroup(xyz2pos(x + dx, y + dy, bz)) == gref then ok = true end
                      end
                    end end
                    if ok then cands[#cands + 1] = { x, y, bz, blk, ex, ey, math.abs(x - cfg.FORT_X) + math.abs(y - cfg.FORT_Y) + math.abs(bz - cfg.SURFACE_Z) * 3 } end
                  end
                end end end
              end
            end
          end
        end end
      end end
    end
  end
  table.sort(cands, function(a, b) return a[7] < b[7] end)
  local n = 0
  for i = 1, math.min(max, #cands) do
    local c = cands[i]
    if not dry then c[4].designation[c[5]][c[6]].dig = DD.Default c[4].flags.designated = true end
    n = n + 1
  end
  return n, #cands
end

if not (dfhack_flags and dfhack_flags.module) then
  local a = { ... }
  if not util.require_fort() then return end
  if a[1] == 'purge' then
    local n, kept, jobs = purge()
    util.emit({ entfernt = n, gueltig = kept, jobs_entfernt = jobs })
  else
    local ore, zmin, zmax = a[1] or 'HEMATITE', tonumber(a[2]) or cfg.dig_min_z(cfg.aquifer_seen()), tonumber(a[3]) or (cfg.SURFACE_Z - 1)
    local max = tonumber(a[4]) or 60
    local dry = false
    for _, v in ipairs(a) do if v == '--dry' then dry = true end end
    local n, total = run(ore:upper(), zmin, zmax, max, dry)
    util.emit({ gesetzt = n, kandidaten = total, dry = dry })
  end
end
