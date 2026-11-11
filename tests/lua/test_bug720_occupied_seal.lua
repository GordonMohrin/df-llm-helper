-- BUG-720 (Run 16a i1 Basementflew y440: seal c1a1c7a48e hung 40 days at 'Coffin 97,92,129 (a wall wanted)', the audit named 97,92,129 every day and
-- `seal at=audit` said 'nothing to close'): a seal blocked `occupied` (nothing of it can be built: another building stands on its tile) for
-- occupied_days is cancelled by the kernel with the reason, so its slot is free and the next audit (cmd.audit_avoid, tests/test_bug720_audit_avoid.py)
-- names another wall tile of the route.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local Z = 129
local ID = 'c1a1c7a48e0001'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag, mode)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}, mode = mode}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, 94, 88, Z, 100, 96)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end})
  return W
end

local function seal_doc(cells)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '97,92,129 floor', close = 'wall'},
          anchor = {97, 92, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {97, 92, Z}, cells = cells}}}},
          manifest = {v = 2}, materials = {wall = #cells}}
end

T.test('BUG-720: a seal blocked occupied by a coffin is cancelled after occupied_days, PROJECT_BLOCKED names the coffin and the tile', function()
  local W = world('occ720')
  H.hatch(W, 97, 92, Z, '.')                          -- a building of another kind on the wall tile (the fake world's stand-in for the coffin)
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'Cw'}}))
  H.runs(W, 4)
  T.eq(H.proj(W, ID).blocked, 'occupied')
  H.runs(W, 2, 600)                                   -- not yet occupied_days
  T.ok(H.proj(W, ID) ~= nil and H.proj(W, ID).blocked ~= 'cancel', 'still there before occupied_days')
  H.runs(W, 12, 600)
  local P = H.proj(W, ID)
  T.ok(P == nil or P.blocked == 'cancel', 'cancelled: ' .. T.show(P))
  local hit
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do
    if e.d.autocancel then hit = e end
  end
  T.ok(hit, 'a PROJECT_BLOCKED with d.autocancel')
  T.eq(hit.d.why, 'occupied')
  T.ok(hit.d.parts:find('97,92,129', 1, true), hit.d.parts)
  T.ok(hit.msg:find('another wall tile', 1, true), hit.msg)
end)

T.test('BUG-720: occupied_days 0 keeps the old behaviour (blocked for good)', function()
  local W = world('off720')
  runner.CFG.occupied_days = 0
  H.hatch(W, 97, 92, Z, '.')
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'Cw'}}))
  H.runs(W, 30, 600)
  local P = H.proj(W, ID)
  T.ok(P and P.blocked == 'occupied', T.show(P))
  runner.CFG.occupied_days = CFG0.occupied_days
end)

-- siege traffic: the cancel is PEACE only. In a SIEGE the blocked seal stays as it is (the kernel changes no wall plan, no bridge, no refuge)
T.test('BUG-720: in a SIEGE an occupied seal is not cancelled (PEACE only); no bridge, gate or lockdown behaviour is touched', function()
  local W = world('siege720', 'SIEGE')
  H.hatch(W, 97, 92, Z, '.')
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'Cw'}}))
  H.runs(W, 40, 600)
  local P = H.proj(W, ID)
  T.ok(P and P.blocked ~= 'cancel', T.show(P))
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do T.ok(not e.d.autocancel, 'no autocancel in a SIEGE') end
end)

T.done()
