-- claude/muell [status | dump N [zmin zmax]] - garbage management (bau, J109): counts loose items (on the floor, outside stockpile/container/workshop),
-- and optionally marks N loose boulders/corpses for the garbage dump ('dump' as in the UI: mark item as garbage; haulers carry it to the 'Garbage Dump' zone).
-- Fair play: only the UI marking (item.flags.dump), no removing/moving items.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local a = { ... }
local mode = a[1] or 'status'
local IT = df.item_type
local function loose(it)
  local f = it.flags
  if f.removed or f.in_inventory or f.in_building or f.in_job or f.garbage_collect or f.trader or f.hostile or f.foreign or f.owned then return false end
  if not f.on_ground then return false end
  if dfhack.items.getGeneralRef(it, df.general_ref_type.CONTAINED_IN_ITEM) then return false end
  local x, y, z = dfhack.items.getPosition(it)
  if not x then return false end
  local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
  if b and b:getType() == df.building_type.Stockpile then return false end
  return true, x, y, z
end
local function is_fort(z, x, y) return z <= 131 and x >= 40 and x <= 150 and y >= 60 and y <= 130 end
-- Dump zones
local dumps = 0
for _, b in ipairs(df.global.world.buildings.all) do
  if b:getType() == df.building_type.Civzone and df.civzone_type[b.type] == 'Dump' then dumps = dumps + 1 end
end
if mode == 'status' then
  local by, byz, total, dumped = {}, {}, 0, 0
  for _, it in ipairs(df.global.world.items.all) do
    local ok, x, y, z = loose(it)
    if ok then
      total = total + 1
      local t = IT[it:getType()]
      by[t] = (by[t] or 0) + 1
      if t == 'BOULDER' then byz[z] = (byz[z] or 0) + 1 end
      if it.flags.dump then dumped = dumped + 1 end
    end
  end
  local top = {}
  for k, v in pairs(by) do top[#top + 1] = { k, v } end
  table.sort(top, function(p, q) return p[2] > q[2] end)
  local s = {}
  for i = 1, math.min(8, #top) do s[#s + 1] = top[i][1] .. '=' .. top[i][2] end
  local zs = {}
  for z, v in pairs(byz) do zs[#zs + 1] = z .. ':' .. v end
  table.sort(zs)
  util.emit({ lose_stapel = total, davon_dump_markiert = dumped, dump_zonen = dumps, typen = table.concat(s, ' '), boulder_je_z = table.concat(zs, ' ') })
  return
end
if mode == 'dump' then
  local n = tonumber(a[2]) or 500
  local zmin, zmax = tonumber(a[3]) or 115, tonumber(a[4]) or 120
  if dumps == 0 then util.emit({ error = 'keine Dump-Zone vorhanden' }) return end
  local m, pend = 0, 0
  for _, it in ipairs(df.global.world.items.all) do
    if it.flags.dump and loose(it) then pend = pend + 1 end
  end
  if pend >= 400 then util.emit({ marked = 0, hinweis = 'noch ' .. pend .. ' markiert, abwarten' }) return end
  for _, it in ipairs(df.global.world.items.all) do
    if m >= n then break end
    local ok, x, y, z = loose(it)
    if ok and not it.flags.dump and not it.flags.forbid then
      local t = IT[it:getType()]
      if ((t == 'CORPSE' or t == 'CORPSEPIECE' or t == 'REMAINS') and is_fort(z, x, y)) then
        it.flags.dump = true
        m = m + 1
      end
    end
  end
  util.emit({ marked = m, vorher_markiert = pend })
end
