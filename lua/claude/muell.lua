-- claude/muell [status | dump N] - garbage management (bau, J109): counts loose items (on the floor, outside stockpile/container/workshop),
-- and optionally marks N loose corpses/remains for the garbage dump ('dump' as in the UI: mark item as garbage; haulers carry it to the 'Garbage Dump' zone).
--   status   loose items by type, boulders per z; items already lying IN a dump zone count as `auf_stapelpunkt_entsorgt`, not as loose
--   dump [N=150]   marks the N corpses/corpse pieces/remains NEAREST to a dump zone that are in the same walk group as that zone
--                  (unreachable ones are skipped); corpses of the fort's own race are never dumped (burial). Ported from the live copy (BUG-420).
-- Used for: tidying up after fights/sieges (optional script). Needs config keys: none (dump zones are read from the game; FORT_BOX only
-- for the old fort filter, which the reachability test replaced).
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
if mode ~= 'status' and mode ~= 'dump' then
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(mode), usage = 'claude/muell [status | dump [N]]' })
  return
end
-- Dump zones
local dumps, dzones = 0, {}
for _, b in ipairs(df.global.world.buildings.all) do
  if b:getType() == df.building_type.Civzone and df.civzone_type[b.type] == 'Dump' then dumps = dumps + 1; dzones[#dzones + 1] = b end
end
local function in_dumpzone(x, y, z)
  for _, b in ipairs(dzones) do
    if z == b.z and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return true end
  end
  return false
end
if mode == 'status' then
  local by, byz, total, dumped, stapel = {}, {}, 0, 0, 0
  for _, it in ipairs(df.global.world.items.all) do
    local ok, x, y, z = loose(it)
    if ok and in_dumpzone(x, y, z) then
      stapel = stapel + 1
    elseif ok then
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
  util.emit({ lose_stapel = total, auf_stapelpunkt_entsorgt = stapel, davon_dump_markiert = dumped, dump_zonen = dumps, typen = table.concat(s, ' '), boulder_je_z = table.concat(zs, ' ') })
  return
end
if mode == 'dump' then
  local n = tonumber(a[2]) or 150
  local zones = {}
  for _, b in ipairs(dzones) do
    local c = xyz2pos(math.floor((b.x1 + b.x2) / 2), math.floor((b.y1 + b.y2) / 2), b.z)
    zones[#zones + 1] = { x = c.x, y = c.y, z = c.z, g = dfhack.maps.getWalkableGroup(c) }
  end
  if #zones == 0 then util.emit({ error = 'keine Dump-Zone vorhanden' }) return end
  local fr = df.global.plotinfo.race_id
  local m, pend = 0, 0
  for _, it in ipairs(df.global.world.items.all) do
    if it.flags.dump and loose(it) then pend = pend + 1 end
  end
  if pend >= 400 then util.emit({ marked = 0, hinweis = 'noch ' .. pend .. ' markiert, abwarten' }) return end
  local cand, skipped = {}, { dwarf = 0, unreachable = 0 }
  for _, it in ipairs(df.global.world.items.all) do
    local ok, x, y, z = loose(it)
    if ok and not it.flags.dump and not it.flags.forbid and not in_dumpzone(x, y, z) then   -- already on the dump: done
      local t = IT[it:getType()]
      if t == 'CORPSE' or t == 'CORPSEPIECE' or t == 'REMAINS' then
        if t ~= 'REMAINS' and it.race == fr then skipped.dwarf = skipped.dwarf + 1   -- own race: burial, not the dump
        else
          local g = dfhack.maps.getWalkableGroup(xyz2pos(x, y, z))
          local best
          for _, zn in ipairs(zones) do
            if g ~= 0 and g == zn.g then
              local d = math.abs(zn.x - x) + math.abs(zn.y - y) + 3 * math.abs(zn.z - z)
              if not best or d < best then best = d end
            end
          end
          if best then cand[#cand + 1] = { it = it, d = best, t = t } else skipped.unreachable = skipped.unreachable + 1 end
        end
      end
    end
  end
  table.sort(cand, function(p, q) return p.d < q.d end)
  local by = {}
  for i = 1, math.min(n, #cand) do
    cand[i].it.flags.dump = true
    m = m + 1
    by[cand[i].t] = (by[cand[i].t] or 0) + 1
  end
  util.emit({ marked = m, vorher_markiert = pend, kandidaten_erreichbar = #cand, uebersprungen = skipped, je_typ = by,
              naechster_rest_dist = cand[n + 1] and cand[n + 1].d or nil })
end
