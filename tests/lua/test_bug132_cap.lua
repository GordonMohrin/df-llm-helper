-- BUG-132: the pop cap follows Gordon's D-01 = B answer (R0 cap 100): the kernel's no-plan default ceiling and the
-- readiness R2 ceiling (siege trigger - 5 = 75) never pull the cap below the R0/R1 cap.
local T = require('testlib')
local H = require('kern_world')
local X = require('wp6_world')
local kern = require('dfllm.kern')

T.test('no plan applied: the default ceiling follows D-01 (B: option B 100; A: option A 55)', function()
  local W = H.world{tag = 'bug132b'}
  local ok, msg = H.boot(W, {modules = {}})
  assert(ok, msg)
  local pol = kern.K().plan.policy
  T.eq({pol.option, pol.pop_ceiling}, {'B', 100})
  kern.stop()
  local W2 = H.world{tag = 'bug132a'}
  luahost.mkdir_recursive(W2.dir .. '/config')
  H.write(W2.dir .. '/config/decisions.yaml', 'D-01: A\n')
  ok, msg = H.boot(W2, {modules = {}})
  assert(ok, msg)
  pol = kern.K().plan.policy
  T.eq({pol.option, pol.pop_ceiling}, {'A', 55})
  kern.stop()
end)

T.test('R2 ceiling: siege trigger - 5 never below the R1 cap (shipped 100 stays 100; option A caps 75)', function()
  local units = X.citizens(50, 1, {})
  local W = X.world{units = units, persist = {}}
  W.K.cfg.decisions['D-01'] = 'B'
  W.set_plan{v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'B', pop_ceiling = 100, beauty = 'used_rooms'}}
  W.econ, W.snap, W.runner = X.economy(), X.snapshot(), X.runner('P5')
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, W.runner}, {'sense', 'gate'})
  local R = X.mod('readiness')
  local saved = R.CAPS
  R.CAPS = {[0] = 100, [1] = 100, [2] = 100, [3] = 250}
  T.eq({X.call(W, 'readiness', 'ceiling', 1)}, {100, 'R1'})
  T.eq({X.call(W, 'readiness', 'ceiling', 2)}, {100, 'R2'}, 'reaching R2 must not freeze the cap at 75')
  R.CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  T.eq({X.call(W, 'readiness', 'ceiling', 2)}, {75, 'R2'}, 'the old caps: R2 = 75')
  R.CAPS = saved
end)

T.done()
