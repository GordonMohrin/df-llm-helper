-- NEU1 (decision E4): the P0 deliverable `startset` (plans/year1.json) is met through startset.done(); the status line names the
-- parts it waits for ('startset shops,office'); without the module the deliverable is skipped (absent module, as before).
local T = require('testlib')
local H = require('runner_world')
local C = require('dfllm.util.contract')
local runner = require('dfllm.runner')

local PHASES = {
  {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'startset'}}},
  {id = 'P1', title = 'p1', approve = false, deliver = {}},
}

local function fresh(tag, with_mod, persist)
  local W = H.world{tag = tag, phases = {v = 2, kind = 'phases', phases = PHASES}, persist = persist}
  W.load(runner)
  if with_mod then
    local m = {name = 'startset', every = {ticks = 1200}}
    W.ss = {done = false, wait = 'shops,office'}
    function m.done() return W.ss.done end
    function m.waiting() return W.ss.wait end
    function m.escalated() return W.ss.esc == true end
    W.load(m)
  end
  return W
end

T.test('P0 waits for the start set and names its parts; done -> P1', function()
  local W = fresh('ss', true)
  H.runs(W, 2)
  local s = W.state()
  T.eq(s.phase, 'P0')
  T.eq(s.phw and s.phw.wait, {'startset shops,office'})
  T.eq(C.check_state(s), {}, 'the state keeps its contract')
  W.ss.done, W.ss.wait = true, ''
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1')
end)

T.test('without the startset module the deliverable is skipped', function()
  local W = fresh('noss', false)
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1')
end)

-- NEU1 retry (verifier): `startset` is not plan-driven, PLAN_EXHAUSTED never fires for it; once the set escalated
-- (DECISION_NEEDED startset) and fortcore stage 1 exists, the kernel waives it with a logged reason and P0 goes on
T.test('escalated start set + fortcore stage 1 -> auto-waived, P1; escalated without a core -> P0 holds', function()
  local W = fresh('ssw', true, {['m.runner'] = {hist = {fortcore = {ps = 1, n = 0}}}})
  W.ss.esc = true
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1')
  local wv = W.K.persist.get('phase').waive
  T.eq(wv[1].d, 'startset'); T.eq(wv[1].by, 'kernel')
  T.ok(wv[1].why:find('fortcore stage 1', 1, true) ~= nil, wv[1].why)
  local W2 = fresh('ssw2', true)
  W2.ss.esc = true
  H.runs(W2, 2)
  T.eq(W2.state().phase, 'P0', 'no core: the DECISION_NEEDED is the signal, no waiver')
  local W3 = fresh('ssw3', true, {['m.runner'] = {hist = {fortcore = {ps = 1, n = 0}}}})
  H.runs(W3, 2)
  T.eq(W3.state().phase, 'P0', 'a core but not escalated: the set is still being built')
end)

T.done()
