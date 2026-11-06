-- dfllm.util.wound (BUG-557): which wounds of a unit still need treatment. unit.body.wounds keeps every wound the unit ever
-- had, healed scars too (Run 16d i4 Trumpetrealms y404: `wounds 1` on almost every dwarf, bleed 0, blood 100 %): the length of
-- the list says nothing. A wound counts while one of its parts bleeds (unit_wound.parts[j].bleeding, BUG-137); the health
-- care flag (DF's own "needs a doctor") counts with any wound on the list; lost blood counts with the flag. A wound whose
-- parts cannot be read counts (as the list length did before): a read that fails is no healed scar.
local W = {}

local function num(v) return math.type(v) ~= nil and v or nil end

-- {n = wounds on the list, bleed = wounds with a bleeding part, unread = wounds without readable parts, care = the
-- needs_healthcare flag, low = blood below its maximum}; nil when the body cannot be read
function W.state(u)
  local ok, r = pcall(function()
    local b = u.body
    if b == nil then return nil end
    local list = b.wounds
    local s = {n = #list, bleed = 0, unread = 0, care = false, low = false}
    for _, wd in ipairs(list) do
      local okp, parts = pcall(function() return wd.parts end)
      if not okp or parts == nil then s.unread = s.unread + 1
      else
        for _, pt in ipairs(parts) do
          if (num(pt.bleeding) or 0) > 0 then s.bleed = s.bleed + 1; break end
        end
      end
    end
    local okh, care = pcall(function() return u.health ~= nil and u.health.flags.needs_healthcare == true end)
    s.care = okh and care == true
    s.low = type(b.blood_count) == 'number' and type(b.blood_max) == 'number' and b.blood_count < b.blood_max
    return s
  end)
  if ok then return r end
  return nil
end

-- true when a wound of the unit needs treatment now (see above); false for old scars only
function W.needs_treatment(u)
  local s = W.state(u)
  if not s then return false end
  return s.bleed > 0 or s.unread > 0 or (s.care and (s.n > 0 or s.low))
end

return W
