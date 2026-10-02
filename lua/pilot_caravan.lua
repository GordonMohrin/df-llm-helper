-- claude/pilot_caravan release [--apply]   (dfpilot spec 02, NOT TESTED LIVE)
-- Send a stuck caravan home: sets unit.flags1.left = true ONLY for merchant units (isMerchant, incl. caravan animals
-- with the merchant flag), never for citizens/pets/guests. Fair-play exception: the player's standing permission 2026-10-01
-- (exception register FP09); dfpilot calls this only with a register entry. Without --apply it only displays.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local apply = false
for _, x in ipairs(a) do if x == '--apply' then apply = true end end
if a[1] ~= 'release' then util.emit({ ok = false, error = 'Usage: claude/pilot_caravan release [--apply]' }) return end

local list = {}
for _, u in ipairs(df.global.world.units.active) do
  if dfhack.units.isMerchant(u) and not dfhack.units.isCitizen(u) and not dfhack.units.isPet(u)
      and not dfhack.units.isFortControlled(u) and not u.flags1.left then
    list[#list + 1] = u
  end
end
if apply then
  for _, u in ipairs(list) do u.flags1.left = true end
end
local ids = {}
for _, u in ipairs(list) do ids[#ids + 1] = u.id end
util.emit({ ok = true, released = apply and #list or 0, candidates = ids, dry = not apply })
