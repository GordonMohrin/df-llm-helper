-- claude/dig z x1 y1 x2 y2 [mode]   mode: d=dig (default) j=stairs down u=stairs up i=up+down r=ramp h=shaft (channel) x=remove designation
-- Sets dig designations like a player in the menu: DISCOVERED tiles are checked (wall tiles for d/u/i/r, wall/floor for j/h;
-- open tiles are skipped). UNDISCOVERED tiles are designated blindly, exactly like a player dragging a dig box over unrevealed
-- rock: their tiletype/shape is never read and never a reason to skip them (fair play, BUG-418); only the configured
-- barrier boxes (config.SPERR_BOXEN) are left out. Output `blind` = number of undiscovered tiles designated.
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
if not util.require_fort() then return end
local a = { ... }
local z = tonumber(a[1]); local x1, y1, x2, y2 = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
local mode = a[6] or 'd'
if not (z and x1 and y1 and x2 and y2) then util.emit({ error = 'usage: claude/dig z x1 y1 x2 y2 [d|j|u|i|r|h|x]' }) return end
local DD = df.tile_dig_designation
local M = { d = DD.Default, j = DD.DownStair, u = DD.UpStair, i = DD.UpDownStair, r = DD.Ramp, h = DD.Channel, x = DD.No }
local dm = M[mode]
if dm == nil then util.emit({ error = 'mode?' }) return end
local n, skipped, blind = 0, 0, 0
for x = math.min(x1, x2), math.max(x1, x2) do
  for y = math.min(y1, y2), math.max(y1, y2) do
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if blk then
      local des = blk.designation[x % 16][y % 16]
      local ok = false
      if des.hidden then
        -- undiscovered: blind designation like the menu; no tiletype/shape read (BUG-418), only the configured barrier boxes
        ok = mode == 'x' or not cfg.in_sperr_box(x, y, z)
        if ok and mode ~= 'x' then blind = blind + 1 end
      else
        local sh = df.tiletype_shape[df.tiletype.attrs[blk.tiletype[x % 16][y % 16]].shape]
        -- Validation (30.09. erkundung): designations ONLY on suitable tiles, otherwise 'Inappropriate dig square' (blocks miners).
        -- d/u/i/r: wall tiles only (shape WALL). j (stairs down) / h (channel): wall or floor. Never EMPTY/SAPLING/TREE/stairs/ramp/water.
        if cfg.is_sperre(x, y, z) and mode ~= 'x' then ok = false  -- Blocked tile (construction/shaft D): never designate
        elseif mode == 'x' then ok = true
        elseif sh == 'WALL' then ok = true
        elseif (mode == 'j' or mode == 'h') and sh == 'FLOOR' then ok = true end
      end
      if ok then
        des.dig = dm
        if mode ~= 'x' then blk.flags.designated = true end
        n = n + 1
      else skipped = skipped + 1 end
    end
  end
end
util.emit({ ok = true, gesetzt = n, uebersprungen = skipped, blind = blind, z = z, mode = mode })
