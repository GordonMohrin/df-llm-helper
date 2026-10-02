--@ module = true
-- claude/kohle [run [N]|start|stop|status]  - coal supply (erkundung, run 5): designates up to N (default 40) DISCOVERED coal wall tiles
-- (COAL_BITUMINOUS, shape WALL, hidden=false, no dig designation yet, z >= config.dig_min_z, reachable = neighbor walkable) near the shaft (99,95).
-- Fair play: discovered tiles only, dig designations only, NO priority events. start = `run` every 1500 ticks (repeat-util), afterwards `erzdig ALL`.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local repeatUtil = require('repeat-util')
local cfg = reqscript('claude/config')
local KEY = 'claude-kohle'

local function walk(x, y, z)
  local tt = dfhack.maps.getTileType(x, y, z)
  if not tt then return false end
  local sh = df.tiletype_shape[df.tiletype.attrs[tt].shape]
  return sh == 'FLOOR' or sh:find('STAIR') ~= nil or sh:find('RAMP') ~= nil
end

function run(N)
  N = N or 40
  local minz = cfg.dig_min_z(cfg.aquifer_seen())
  local list = {}
  local mx, my, mz = dfhack.maps.getTileSize()
  for bz = minz, mz - 1 do for bx = 0, mx // 16 - 1 do for by = 0, my // 16 - 1 do
    local blk = dfhack.maps.getBlock(bx, by, bz)
    if blk then for _, ev in ipairs(blk.block_events) do
      if df.block_square_event_mineralst:is_instance(ev) then
        local raw = df.inorganic_raw.find(ev.inorganic_mat)
        if raw and raw.id == 'COAL_BITUMINOUS' then
          for ey = 0, 15 do
            local bits = ev.tile_bitmask.bits[ey]
            if bits ~= 0 then for ex = 0, 15 do if bits & (1 << ex) ~= 0 then
              local d = blk.designation[ex][ey]
              local sh = df.tiletype_shape[df.tiletype.attrs[blk.tiletype[ex][ey]].shape]
              if not d.hidden and sh == 'WALL' and d.dig == df.tile_dig_designation.No and not d.water_table then
                local x, y = blk.map_pos.x + ex, blk.map_pos.y + ey
                if (walk(x + 1, y, bz) or walk(x - 1, y, bz) or walk(x, y + 1, bz) or walk(x, y - 1, bz)) and not cfg.is_sperre(x, y, bz) then
                  list[#list + 1] = { x, y, bz, math.abs(x - 99) + math.abs(y - 95) }
                end
              end
            end end end
          end
        end
      end
    end end
  end end end
  table.sort(list, function(a, b) return a[4] < b[4] end)
  local n = 0
  for i = 1, math.min(N, #list) do
    local p = list[i]
    local blk = dfhack.maps.getTileBlock(p[1], p[2], p[3])
    blk.designation[p[1] % 16][p[2] % 16].dig = df.tile_dig_designation.Default
    blk.flags.designated = true
    n = n + 1
  end
  return n, #list
end

local a = { ... }
if dfhack_flags and dfhack_flags.module then return end
local cmd = a[1] or 'status'
if cmd == 'run' then
  local n, k = run(tonumber(a[2]))
  util.emit({ designiert = n, kandidaten = k })
elseif cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, 1500, 'ticks', function() pcall(run, 40) end)
  util.emit({ ok = true, intervall = 1500 })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ ok = true })
else
  util.emit({ laeuft = repeatUtil.isScheduled and repeatUtil.isScheduled(KEY) or 'unbekannt' })
end
