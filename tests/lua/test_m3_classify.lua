-- M3 (BUG-111, Run 14 y707 notes 94/96): the census counts as an invader only a unit DF treats as hostile to the player:
-- not a merchant, diplomat, visitor, restrained or child; an unconscious one stays counted but is marked (it wakes up).
-- The unit sheet's flags are the ones a player sees; the census names the units it left out and why.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function world(units)
  local W = S.world{units = units}
  S.load(W)
  return W
end

T.test('BUG-111: an invader that is a merchant, diplomat, visitor, restrained or a child is no hostile; the census names why',
       function()
  local W = world{
    S.cit(1, 60, 70),
    S.inv(201, 51, 30), S.inv(202, 52, 30, Z, {merchant = true}), S.inv(203, 53, 30, Z, {diplomat = true}),
    S.inv(204, 54, 30, Z, {visitor = true}), S.inv(205, 55, 30, Z, {chained = true}),
    S.inv(206, 56, 30, Z, {adult = false}), S.inv(207, 57, 30, Z, {baby = true, adult = false}),
    -- never excluded: an uninvited visitor (thief, ambusher), an active invader or marauder flagged as visitor
    S.inv(208, 58, 30, Z, {visitor = true, visitor_uninvited = true}), S.inv(209, 59, 30, Z, {visitor = true, active_invader = true}),
    S.inv(210, 60, 30, Z, {visitor = true, marauder = true}),
  }
  W.run(10)
  local h = W.K.census.h
  T.eq({h.vis, h.inv, #h.list}, {4, 4, 4}, 'old code: ten invaders')
  local seen = {}
  for _, e in ipairs(h.list) do seen[#seen + 1] = e.id end
  table.sort(seen)
  T.eq(seen, {201, 208, 209, 210}, 'an uninvited visitor, an active invader and a marauder stay hostile')
  T.eq(h.nben, 6)
  local why = {}
  for _, b in ipairs(h.benign) do why[b.id] = b.why end
  T.eq(why, {[202] = 'merchant', [203] = 'diplomat', [204] = 'visitor', [205] = 'restrained', [206] = 'child',
             [207] = 'child'})
end)

T.test('BUG-111: an unconscious invader stays counted (it wakes up) and is marked uc; a normal one is not', function()
  local W = world{S.cit(1, 60, 70), S.inv(201, 51, 30, Z, {unconscious = 300}), S.inv(202, 52, 30)}
  W.run(10)
  local h = W.K.census.h
  T.eq({h.vis, h.inv, h.nben or 0}, {2, 2, 0})
  local uc = {}
  for _, e in ipairs(h.list) do uc[e.id] = e.uc end
  T.eq(uc, {[201] = 1})
end)

T.done()
