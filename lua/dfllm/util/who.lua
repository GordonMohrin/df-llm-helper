-- dfllm.util.who (BUG-103, Run 14 note 74): who a report about a unit's mood, thirst or hunger is about.
-- The census (sense.lua) holds every sane citizen AND resident (isCitizen or isResident, API.txt:1696): a resident lives in
-- the fort but is no citizen of the player (BUG-088), and a merchant, a visitor or a member of a caravan stands outside it.
-- Nothing the kernel does for a citizen (a workshop, materials, a drink nook, caregivers, the lockdown's rescue) reaches them,
-- so a MOOD_CRITICAL / DECISION_NEEDED about one asks the player for what cannot be done (unit 38663: a Fey wax worker of civ 29
-- 140 tiles from the fort, thirst 67,117 of 75,000, "workshop none claimed").
local M = {}

-- a citizen of the player (dfhack.units.isCitizen: sane, own civilization and group, no merchant, no visitor)
function M.citizen(u)
  if u == nil then return false end
  local ok, yes = pcall(dfhack.units.isCitizen, u)
  return ok and yes == true
end

return M
