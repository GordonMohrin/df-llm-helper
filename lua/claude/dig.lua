-- claude/dig z x1 y1 x2 y2 [mode]   mode: d=dig (default) j=stairs down u=stairs up i=up+down r=ramp h=shaft (channel) x=remove designation
-- Sets dig designations like a player in the menu: wall tiles (d/u/i/r) or wall/floor (j/h); open tiles are skipped.
-- NOTE (BUG-418): undiscovered tiles are judged by their real shape as well (the menu lets a player designate them
-- blindly); whether hidden tiles should be designated blindly or skipped is an open decision of the player.
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
local n, skipped = 0, 0
for x = math.min(x1, x2), math.max(x1, x2) do
  for y = math.min(y1, y2), math.max(y1, y2) do
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if blk then
      local tt = blk.tiletype[x % 16][y % 16]
      local shape = df.tiletype.attrs[tt].shape
      local sh = df.tiletype_shape[shape]
      -- Validation (30.09. erkundung): designations ONLY on suitable tiles, otherwise 'Inappropriate dig square' (blocks miners).
      -- d/u/i/r: wall tiles only (shape WALL). j (stairs down) / h (channel): wall or floor. Never EMPTY/SAPLING/TREE/stairs/ramp/water.
      local ok = false
      if cfg.is_sperre(x, y, z) and mode ~= 'x' then ok = false  -- Blocked tile (construction/shaft D): never designate
      elseif mode == 'x' then ok = true
      elseif sh == 'WALL' then ok = true
      elseif (mode == 'j' or mode == 'h') and sh == 'FLOOR' then ok = true end
      if ok then
        blk.designation[x % 16][y % 16].dig = dm
        if mode ~= 'x' then blk.flags.designated = true end
        n = n + 1
      else skipped = skipped + 1 end
    end
  end
end
util.emit({ ok = true, gesetzt = n, uebersprungen = skipped, z = z, mode = mode })
