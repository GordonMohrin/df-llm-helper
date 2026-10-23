-- sense (BUG-062, Run 14 note 52): census.g = the fort's own ghosts met in the hostile scan; care's ghost number
-- reads it. Fails on f17e2b3 (no census.g).
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function world(units, opts)
  opts = opts or {}
  opts.units = units
  local W = S.world(opts)
  S.load(W, opts.extra)
  return W
end

T.test('census.g: own ghosts (own group, or the fort civ), sorted; a foreign ghost and a plain undead are no ghosts of ours', function()
  local W = world{
    S.cit(1, 60, 70),
    {id = 403, pos = {61, 70, Z}, undead = true, ghost = true, own_group = true},   -- a citizen's ghost inside Kern+
    {id = 401, pos = {62, 70, Z}, undead = true, ghost = true, civ_id = 7},         -- a berserker's ghost (civ link only)
    {id = 402, pos = {51, 30, Z}, undead = true, ghost = true, civ_id = 9},         -- another civ's ghost: a hostile
    {id = 404, pos = {52, 30, Z}, undead = true, civ_id = 7},                       -- an undead that is no ghost
  }
  df.global.plotinfo.civ_id = 7
  W.run(10)
  local g = W.K.census.g
  T.eq({g.n, g.ids}, {2, {401, 403}})
  T.ok(g.tick >= 0)
  T.eq(W.K.census.h.list[1].id, 402, 'the hostiles are unchanged')
  df.global.plotinfo.civ_id = nil
end)

T.test('census.g is empty without ghosts and capped at GHOST_MAX', function()
  local W = world{S.cit(1, 60, 70)}
  W.run(10)
  T.eq({W.K.census.g.n, W.K.census.g.ids}, {0, {}})
  local units = {S.cit(1, 60, 70)}
  for i = 1, 230 do units[#units + 1] = {id = 1000 + i, pos = {61, 70, Z}, undead = true, ghost = true, own_group = true} end
  local W2 = world(units)
  W2.run(60)
  T.eq(W2.K.census.g.n, 200)
  T.eq(#W2.K.census.g.ids, 200)
end)

T.done()
