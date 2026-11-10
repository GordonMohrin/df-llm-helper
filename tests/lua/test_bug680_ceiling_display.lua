-- BUG-680 (Run 16d i4 Trumpetrealms y455: the plan applied with ceiling 66, the status said 'plan 60'): the hold text names the ceiling that
-- holds (the gate), and a plan.reload re-evaluates the cap at once (readiness.plan_changed, kern.lua calls it), not at the next step.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function plan(ceiling)
  return {v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
          policy = {option = 'A', pop_ceiling = ceiling, beauty = 'used_rooms'}}
end

local function world(n, ceiling)
  local units = X.citizens(n, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan(plan(ceiling))
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ = X.economy({drink_d = 200, food_d = 90, meals = 5})
  X.load(W, {'military', 'readiness'}, {W.econ, X.snapshot(), runner}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 100, [1] = 100, [2] = 100, [3] = 250}
  return W
end

T.test('BUG-680: a new plan ceiling shows and binds at plan.reload, the hold text names the gate, not the old max-pop', function()
  local W = world(60, 60)
  W.run(2400, {skip = 9}); W.state()
  local p = W.state().pop
  T.eq({p.gate_cap, p.hold}, {60, 'plan 60'}, 'the plan holds 60')
  W.set_plan(plan(66))                                      -- plan.reload: K.plan is the new one, no step has run yet
  T.eq(W.state().pop.hold, 'plan 60', 'before the fix point: the old reading stands until the module is told')
  T.ok(X.call(W, 'readiness', 'plan_changed'), 'plan_changed answers')
  p = W.state().pop
  T.eq({p.gate_cap, p.hold}, {66, 'plan 66'}, 'old code: the gate 66 with the text plan 60 (st.cap)')
  T.eq(X.call(W, 'readiness', 'ceiling', 0), 66)
end)

T.done()
