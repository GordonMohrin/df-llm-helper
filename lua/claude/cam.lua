-- claude/cam <x> <y> <z>   center the camera on a position
-- claude/cam unit <id>     camera on a unit (follows it until 'cam stop')
-- claude/cam squad         camera on the squad "Wache" (first living member), follows it
-- claude/cam stop          stop following
-- Viewport only, changes nothing in the game (spectator aid for the player).
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local pi = df.global.plotinfo

-- The camera director (claude/schau) stays still while the main thread sets the camera by hand (2 min)
if a[1] ~= 'stop' then pcall(function() reqscript('claude/schau').hold(120) end) end

local function center(pos)
  dfhack.gui.revealInDwarfmodeMap(pos, true)
  util.emit({ ok = true, x = pos.x, y = pos.y, z = pos.z })
end

if a[1] == 'stop' then
  pi.follow_unit = -1
  util.emit({ ok = true, following = false })
elseif a[1] == 'unit' then
  local u = df.unit.find(tonumber(a[2]) or -1)
  if not u then util.emit({ ok = false, error = 'Einheit nicht gefunden' }) return end
  pi.follow_unit = u.id
  center(xyz2pos(dfhack.units.getPosition(u)))
elseif a[1] == 'squad' then
  local ent = df.historical_entity.find(pi.group_id)
  for _, sid in ipairs(ent.squads) do
    local sq = df.squad.find(sid)
    for i = 0, #sq.positions - 1 do
      local occ = sq.positions[i].occupant
      if occ >= 0 then
        local hf = df.historical_figure.find(occ)
        local u = hf and df.unit.find(hf.unit_id)
        if u and not dfhack.units.isDead(u) then
          pi.follow_unit = u.id
          center(xyz2pos(dfhack.units.getPosition(u)))
          return
        end
      end
    end
  end
  util.emit({ ok = false, error = 'kein lebendes Truppmitglied' })
else
  local x, y, z = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
  if not (x and y and z) then util.emit({ ok = false, error = 'Aufruf: cam x y z | unit id | squad | stop' }) return end
  pi.follow_unit = -1
  center(xyz2pos(x, y, z))
end
