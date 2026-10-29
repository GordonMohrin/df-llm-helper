-- FR-100 (G18): the phase deliverable `kit` (plans/year1.json P6: {"k": "kit", "pct": 80}) passes once that share of
-- the soldiers is fully equipped (state mil.kit: armor in every slot and a weapon in hand); no soldiers never passes; an
-- absent military module skips it like every deliverable of an absent module.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local PHASES = {
  {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'kit', pct = 80}}},
  {id = 'P1', title = 'p1', approve = false, deliver = {}},
}

local function fresh(tag)
  local W = H.world{tag = tag, phases = {v = 2, kind = 'phases', phases = PHASES}}
  W.load(runner)
  return W
end

local function fake_mil(kit)
  local M = {name = 'military', every = {ticks = 3600}, kit = kit}
  function M.state()
    if not M.kit then return {} end
    return {mil = {squads = 1, soldiers = M.kit.n, worn = 50, cv = 10, metal_pct = 0, on_station = 0, kit = M.kit}}
  end
  return M
end

T.test('FR-100: kit pct passes at >= pct % fully equipped soldiers, not below, never without soldiers', function()
  local W = fresh('kit')
  local m = fake_mil({n = 5, full = 3, armor = 3, weapon = 5, wood = 4, tr = 1})
  W.load(m); W.state()                    -- (k_mock: the view is the last composed state)
  H.runs(W, 2)
  T.eq(W.state().phase, 'P0', '3/5 = 60 % < 80 %')
  m.kit = {n = 0, full = 0, armor = 0, weapon = 0, wood = 0, tr = 0}; W.state()
  H.runs(W, 2)
  T.eq(W.state().phase, 'P0', 'no soldiers: not equipped')
  m.kit = {n = 5, full = 4, armor = 4, weapon = 5, wood = 4, tr = 1}; W.state()
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1', '4/5 = 80 %')
end)

T.test('FR-100: without a military module the kit deliverable is skipped', function()
  local W = fresh('kit2')
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1')
end)

T.done()
